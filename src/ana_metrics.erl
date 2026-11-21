%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Metrics (spec 019, RF-019-02): counters in ETS, exposed at /metrics in the
%% Prometheus text format and sampled every 5 min for the studio charts.
-module(ana_metrics).
-export([init_table/0, observe/4, prometheus/0, snapshot/0]).

-define(TAB, ana_metrics).
-define(BUCKETS, [10, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000, 60000]).

init_table() ->
    _ = ets:new(?TAB, [named_table, public, set, {write_concurrency, true}]),
    ok.

%% One finished execution.
-spec observe(binary(), binary(), integer(), number()) -> ok.
observe(Program, Status, DurationMs, SqlMs) ->
    ok = inc({executions, Program, Status}, 1),
    ok = inc({duration_sum, Program}, DurationMs),
    ok = inc({duration_count, Program}, 1),
    ok = inc({sql_ms, Program}, round(SqlMs)),
    lists:foreach(fun(B) -> ok = inc({duration_bucket, Program, B}, 1) end, [B || B <- ?BUCKETS, DurationMs =< B]).

inc(Key, N) ->
    _ = try ets:update_counter(?TAB, Key, N, {Key, 0}) catch error:badarg -> 0 end,
    ok.

%% Text exposition format (RF-019-02, CA-019-06).
-spec prometheus() -> iodata().
prometheus() ->
    All = ets:tab2list(?TAB),
    C = ana_execution:counters(),
    Py = catch ana_py_pool:status(),
    Pools = [{P, catch ana_db:status(P)} || P <- [ana_db, ana_db_exec]],
    Mem = erlang:memory(),
    [help("ana_executions_total", "counter", "Finished executions by program and status"),
     [line("ana_executions_total", [{program, P}, {status, S}], V) || {{executions, P, S}, V} <- All],
     help("ana_execution_duration_ms", "histogram", "Execution duration (ms)"),
     [[ [line("ana_execution_duration_ms_bucket", [{program, P}, {le, integer_to_binary(B)}],
              bucket(All, P, B)) || B <- ?BUCKETS],
        line("ana_execution_duration_ms_bucket", [{program, P}, {le, <<"+Inf">>}], V),
        line("ana_execution_duration_ms_sum", [{program, P}], sum_of(All, P)),
        line("ana_execution_duration_ms_count", [{program, P}], V)]
      || {{duration_count, P}, V} <- All],
     help("ana_sql_ms_total", "counter", "Time spent in SQL (ms) by program"),
     [line("ana_sql_ms_total", [{program, P}], V) || {{sql_ms, P}, V} <- All],
     help("ana_executions_running", "gauge", "Executions in progress"),
     line("ana_executions_running", [], maps:get(executions, C, 0)),
     help("ana_python_ready", "gauge", "Prewarmed Python processes ready"),
     line("ana_python_ready", [], case Py of #{ready := R} -> R; _ -> 0 end),
     help("ana_db_pool", "gauge", "Database pool connections by state"),
     [[line("ana_db_pool", [{pool, atom_to_binary(P)}, {state, atom_to_binary(K)}], maps:get(K, St, 0))
       || K <- [free, busy, waiting]] || {P, St} <- Pools, is_map(St)],
     help("ana_beam_memory_bytes", "gauge", "Erlang VM memory"),
     [line("ana_beam_memory_bytes", [{kind, atom_to_binary(K)}], V) || {K, V} <- Mem, lists:member(K, [total, processes, ets, binary])],
     help("ana_beam_processes", "gauge", "Erlang processes"),
     line("ana_beam_processes", [], erlang:system_info(process_count))].

bucket(All, P, B) ->
    case lists:keyfind({duration_bucket, P, B}, 1, All) of {_, V} -> V; false -> 0 end.
sum_of(All, P) ->
    case lists:keyfind({duration_sum, P}, 1, All) of {_, V} -> V; false -> 0 end.

help(Name, Type, Text) -> ["# HELP ", Name, " ", Text, "\n# TYPE ", Name, " ", Type, "\n"].

line(Name, [], V) -> [Name, " ", num(V), "\n"];
line(Name, Labels, V) ->
    [Name, "{", lists:join(",", [[atom_to_binary(K), "=\"", escape(L), "\""] || {K, L} <- Labels]), "} ", num(V), "\n"].

num(V) when is_integer(V) -> integer_to_binary(V);
num(V) when is_float(V) -> float_to_binary(V, [short]).

escape(B) -> binary:replace(binary:replace(B, <<"\\">>, <<"\\\\">>, [global]), <<"\"">>, <<"\\\"">>, [global]).

%% Totals for the studio charts (sampled every 5 min by ana_health).
-spec snapshot() -> map().
snapshot() ->
    All = ets:tab2list(?TAB),
    ByStatus = lists:foldl(fun({{executions, _, S}, V}, Acc) -> Acc#{S => maps:get(S, Acc, 0) + V}; (_, Acc) -> Acc end,
                           #{}, All),
    #{executions => ByStatus,
      duration_ms => lists:sum([V || {{duration_sum, _}, V} <- All]),
      sql_ms => lists:sum([V || {{sql_ms, _}, V} <- All]),
      running => maps:get(executions, ana_execution:counters(), 0),
      memory_mb => erlang:memory(total) div (1024 * 1024),
      processes => erlang:system_info(process_count)}.
