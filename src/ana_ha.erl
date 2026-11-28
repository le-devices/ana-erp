%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% High availability (spec 023): readiness and liveness, graceful drain,
%% schema compatibility and executions interrupted by a node going down.
-module(ana_ha).
-export([draining/0, refusing/0, live/0, ready/0, drain/0, drain_soft/0, resume/0, schema/0, interrupted/1]).

-define(DRAINING, {?MODULE, draining}).
-define(REFUSING, {?MODULE, refusing}).

%% Out of readiness (the balancer stops sending traffic).
-spec draining() -> boolean().
draining() -> persistent_term:get(?DRAINING, false).

%% New executions refused — only after the balancer had time to notice.
-spec refusing() -> boolean().
refusing() -> persistent_term:get(?REFUSING, false).

%% RF-023-01: the process is up (only restart the container when this fails).
-spec live() -> map().
live() -> #{status => ok, node => ana_config:node_id()}.

%% RF-023-01: ready to receive traffic. Every check is reported.
-spec ready() -> {boolean(), map()}.
ready() ->
    Checks = #{
        not_draining => not draining(),
        database => db_ok(),
        pool => pool_ok(ana_db),
        pool_programs => pool_ok(ana_db_exec),
        python => python_ok(),
        schema => element(1, schema()) =/= incompatible
    },
    Ok = lists:all(fun(V) -> V end, maps:values(Checks)),
    {Ok, #{status => case Ok of true -> ready; false -> not_ready end, node => ana_config:node_id(),
           checks => Checks, schema => element(2, schema())}}.

db_ok() ->
    case catch ana_db:one("SELECT 1 AS ok", []) of
        {ok, #{<<"ok">> := 1}} -> true;
        _ -> false
    end.

pool_ok(Pool) ->
    case catch ana_db:status(Pool) of
        #{free := F, busy := B} -> F + B > 0;
        _ -> false
    end.

python_ok() ->
    case catch ana_py_pool:status() of
        #{ready := R, warming := W, target := T} -> T =:= 0 orelse R + W > 0;
        _ -> false
    end.

%% RF-023-03: migrations applied in the database × migrations this node knows.
%% Unknown ones are fine during a rolling update (expand → migrate → contract)
%% unless one of them is marked "-- ana:breaking".
-spec schema() -> {compatible | newer | incompatible, map()}.
schema() ->
    Known = [M || {M, _} <- ana_migrate:known()],
    case catch ana_db:rows("SELECT name FROM ana_system.migration WHERE name NOT LIKE 'demo/%'", []) of
        {ok, Rows} ->
            Unknown = [N || #{<<"name">> := N} <- Rows] -- Known,
            Breaking = case Unknown of
                [] -> [];
                _ ->
                    {ok, B} = ana_db:rows("SELECT name FROM ana_system.migration_flag "
                                          "WHERE flag = 'breaking' AND name = ANY($1::text[])", [Unknown]),
                    [N || #{<<"name">> := N} <- B]
            end,
            State = if Breaking =/= [] -> incompatible; Unknown =/= [] -> newer; true -> compatible end,
            {State, #{state => State, unknown => Unknown, breaking => Breaking}};
        _ ->
            {compatible, #{state => unknown}}
    end.

%% RF-023-02: called by ana_app:prep_stop/1 when the node is asked to stop.
-spec drain() -> ok.
drain() ->
    persistent_term:put(?DRAINING, true),
    logger:notice("draining: not ready; waiting for the balancer to notice"),
    timer:sleep(ana_config:integer("ANA_DRAIN_DELAY_MS", 2000)),
    persistent_term:put(?REFUSING, true),
    logger:notice("draining: refusing new executions, waiting for the running ones"),
    Deadline = erlang:monotonic_time(millisecond) + ana_config:integer("ANA_DRAIN_TIMEOUT_MS", 25000),
    wait_executions(Deadline),
    _ = (catch ranch:suspend_listener(ana_http)),
    ok.

%% Spec 077 (node.drain): out of the balancer while other nodes take the traffic; this node keeps answering what
%% still reaches it (nothing is suspended), so it can be resumed from the same screen.
-spec drain_soft() -> ok.
drain_soft() ->
    persistent_term:put(?DRAINING, true),
    logger:notice("drained by a technical action: not ready (the balancer sends the traffic to the other nodes)"),
    ok.

-spec resume() -> ok.
resume() ->
    persistent_term:put(?DRAINING, false),
    persistent_term:put(?REFUSING, false),
    _ = (catch ranch:resume_listener(ana_http)),
    logger:notice("resumed by a technical action: ready again"),
    ok.

wait_executions(Deadline) ->
    N = maps:get(executions, ana_execution:counters(), 0),
    Now = erlang:monotonic_time(millisecond),
    if
        N =< 0 -> logger:notice("draining: no executions left");
        Now >= Deadline -> logger:warning("draining: ~b execution(s) still running at the deadline", [N]);
        true -> timer:sleep(200), wait_executions(Deadline)
    end.

%% RF-023-04: executions left "running" by a node that went down.
%%   startup — this node's own (none survives a restart);
%%   periodic — any node's, older than twice the execution time ceiling.
-spec interrupted(startup | periodic) -> {ok, non_neg_integer()} | {error, term()}.
interrupted(Mode) ->
    Error = <<"{\"code\": \"INTERRUPTED\", \"message\": \"execução interrompida: o nó que a executava parou\"}"/utf8>>,
    R = case Mode of
        startup ->
            ana_db:exec("UPDATE ana_system.execution SET status = 'error', finished_at = now(), "
                        "error = $2::text::jsonb WHERE status = 'running' AND node = $1",
                        [ana_config:node_id(), Error]);
        periodic ->
            ana_db:exec("UPDATE ana_system.execution SET status = 'error', finished_at = now(), "
                        "error = $2::text::jsonb WHERE status = 'running' "
                        "AND started_at < now() - make_interval(secs => $1)",
                        [2 * ana_settings:get(ceiling_timeout_ms) div 1000, Error])
    end,
    case R of
        {ok, N} when N > 0 -> logger:notice("~b interrupted execution(s) settled (~p)", [N, Mode]), {ok, N};
        {ok, N} -> {ok, N};
        E -> E
    end.
