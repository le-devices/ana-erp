%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% ANA ERP startup (spec 001).
-module(ana_app).
-behaviour(application).
-export([start/2, prep_stop/1, stop/1, configure_roles/0]).

%% Boot steps that change roles and grants run one node at a time (migrations have their own lock).
-define(BOOT_LOCK, 7_741_002).

start(_Type, _Args) ->
    _ = ana_log_json:enable(),                         % RF-019-09
    ok = case ana_db:wait_for_database() of            % RNF-001-07
        ok -> ok;
        {error, Reason} -> exit({database_unavailable, Reason})
    end,
    ok = ana_license:boot_check(),                     % RF-009-07: before any migration
    {ok, Applied} = ana_migrate:run(),                % RF-001-01
    _ = Applied =/= [] andalso ok =:= logger:notice("migrations applied: ~p", [Applied]),
    ok = sync_scoped_role(Applied),                    % spec 009 (D10): new objects reach the scoped role
    ok = configure_roles(),
    {ok, Sup} = ana_sup:start_link(),
    ok = ana_settings:load(),                          % RF-011-05
    ok = ana_mode:load(),                              % spec 077: operation modes
    ok = ana_security:ensure_admin(),                  % RF-001-04
    ok = ana_seeds:apply(),                            % RF-006-08
    _ = ana_parallel:recover(startup),                 % RF-022-04: orphan prepared transactions
    _ = ana_ha:interrupted(startup),                   % RF-023-04: executions of a previous run
    ok = ana_http:start(),
    {ok, Sup}.

%% RF-023-02: SIGTERM → drain (not ready, no new executions, wait the running ones).
prep_stop(State) ->
    _ = (catch ana_ha:drain()),
    State.

stop(_) ->
    _ = (catch cowboy:stop_listener(ana_http)),
    ok.

%% P10: restricted roles get a login with a password known only to the core,
%% plus session limits enforced by the database itself (defense in depth).
configure_roles() ->
    {ok, C} = ana_db:connect(ana_config:db()),
    try
        {ok, _, [{_}]} = epgsql:equery(C, "SELECT now() AT TIME ZONE $1", [list_to_binary(ana_config:timezone())]),
        SqlT = ana_config:integer("ANA_SQL_TIMEOUT_MS", 30000),
        Idle = ana_config:integer("ANA_DEBUG_IDLE_MS", 600000) + 300000,
        Tz = ana_config:timezone(),
        Sql = [[io_lib:format("ALTER ROLE ana_~s WITH LOGIN NOINHERIT CONNECTION LIMIT ~b PASSWORD '~s';",
                              [R, Lim, escape(ana_config:role_password(R))]),
                io_lib:format("ALTER ROLE ana_~s SET statement_timeout = ~b;", [R, SqlT]),
                io_lib:format("ALTER ROLE ana_~s SET idle_in_transaction_session_timeout = ~b;", [R, Idle]),
                io_lib:format("ALTER ROLE ana_~s SET timezone = '~s';", [R, Tz])]
               || {R, Lim} <- [{exec, 200}, {read, 20}]]
              ++ [io_lib:format("ALTER ROLE CURRENT_USER SET timezone = '~s';", [Tz])],
        %% Two nodes starting together would alter the same roles at once ("tuple concurrently updated", the node
        %% stops): one at a time, under a session advisory lock (spec 042 — found by the cluster suite).
        {ok, _, _} = epgsql:squery(C, io_lib:format("SELECT pg_advisory_lock(~b)", [?BOOT_LOCK])),
        Rs = lists:flatten([epgsql:squery(C, Sql)]),
        _ = epgsql:squery(C, io_lib:format("SELECT pg_advisory_unlock(~b)", [?BOOT_LOCK])),
        case [E || {error, E} <- Rs] of
            [] -> ok;
            [E | _] -> exit({configure_roles, E})
        end
    after
        epgsql:close(C)
    end.

escape(B) -> binary:replace(B, <<"'">>, <<"''">>, [global]).

sync_scoped_role([]) -> ok;
sync_scoped_role(_Applied) ->
    {ok, C} = ana_db:connect(ana_config:db()),
    try
        {ok, _, _} = epgsql:squery(C, io_lib:format("SELECT pg_advisory_lock(~b)", [?BOOT_LOCK])),
        R = epgsql:squery(C, "SELECT ana_system.sync_scoped_role()"),
        _ = epgsql:squery(C, io_lib:format("SELECT pg_advisory_unlock(~b)", [?BOOT_LOCK])),
        case R of
            {ok, _, [{N}]} -> logger:notice("scoped role privileges synced: ~s", [N]), ok;
            Other -> logger:warning("scoped role not synced: ~0p", [Other]), ok
        end
    after
        epgsql:close(C)
    end.
