%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Root supervisor (spec 001 plan "Árvore de supervisão").
-module(ana_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% Shared tables belong to the supervisor (they live as long as it does).
    ok = ana_execution:init_tables(),
    ok = ana_remote_system:init_tables(),
    ok = ana_settings:init_cache(),
    ok = ana_program:init_cache(),
    ok = ana_access:init_cache(),
    ok = ana_limits:init_cache(),
    ok = ana_values:init_cache(),             % spec 065: company values in memory on every node
    ok = ana_home:init_cache(),               % spec 048: indicators of the home panel, per user, in memory
    ok = ana_breaker:init_table(),
    ok = ana_metrics:init_table(),
    ok = ana_connector:init_tables(),
    Pool = ana_config:integer("ANA_DB_POOL", 10),
    PoolExec = ana_config:integer("ANA_DB_POOL_EXEC", 20),
    %% Spec 062 (D1): one supervisor per area, each with its own restart budget. The root restarts a
    %% failed area as a whole; a failure in one area never restarts the others.
    Base = [#{id => ana_events, start => {ana_events, start_link, []}},   % spec 062: event bus (pg scope)
            worker(ana_security, []),
            #{id => ana_db, start => {ana_db, start_link, [ana_db, fun ana_config:db/0, Pool]}},
            #{id => ana_db_exec,
              start => {ana_db, start_link, [ana_db_exec, fun() -> ana_config:db_role(exec) end, PoolExec]}},
            worker(ana_listener, []),
            worker(ana_license, [])],
    Exec = [worker(ana_py_pool, []),
            #{id => ana_execution_sup, start => {ana_execution_sup, start_link, []}, type => supervisor},
            worker(ana_api, []),
            worker(ana_access_log, [])],
    Work = [worker(ana_scheduler, []),
            worker(ana_bpm, []),          % single process engine: BPM cases and esteiras (specs 030, 039)
            worker(ana_rules, []),        % spec 051: rules "when… then…" and ERP tasks that resolve by themselves
            worker(ana_watch, []),        % spec 068: change watch installed only where an active rule needs it
            worker(ana_watch_log, []),    % spec 068: master data watched from the history (leader only)
            worker(ana_suggestions, []),  % spec 051: suggestions from usage (background, hourly)
            #{id => ana_connector_sup, start => {ana_connector_sup, start_link, []}, type => supervisor},
            worker(ana_integration, []),
            worker(ana_analytics, []),
            worker(ana_retention, []),
            worker(ana_params, [])],      % spec 077: temporary parameter changes go back by themselves
    Observe = [worker(ana_health, []),
               worker(ana_sql_stats, []),
               worker(ana_advisor, []),
               worker(ana_checks, []),
               worker(ana_ui_perf, []),
               worker(ana_core_view, []),
               worker(ana_disk, []),               % spec 063: how much the database writes
               worker(ana_telemetry, [])],
    Children = [area(ana_base_sup, Base), area(ana_exec_area_sup, Exec), area(ana_work_sup, Work),
                area(ana_observe_sup, Observe)],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 60}, Children}}.

area(Name, Children) ->
    #{id => Name, start => {ana_area_sup, start_link, [Name, Children]}, type => supervisor, shutdown => infinity}.

worker(M, A) ->
    #{id => M, start => {M, start_link, A}}.
