%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Tests of programs, coverage, performance against the previous version, failures by version (spec 064, phase 2).
%%
%% - A program declares its tests beside it (D4): cases in TESTS ({name, params, expect} — the result contains
%%   expect — or {name, params, error} — the run fails with that code) and functions test_<name>() using assert.
%%   Each runs in a REHEARSAL (spec 056: whole, then undone; e-mails, connectors and files held), with line coverage.
%% - The same tests run on the previous version (D5): commands SQL and time compared; a worsening above the
%%   installation's limits is a finding of the quality gate, as is a failing test (and, by policy, a program that
%%   writes without a passing test). Never in production, never calling outside (RNF-064-03).
%% - Failures by version (D6): errors of the program grouped by version and code, with the package that brought the
%%   version and the gate report of that package.
-module(ana_program_tests).

-export([run/2, overview/2, gate_findings/2, failures/1]).

-define(MIN_SQL_DELTA, 2).
-define(MIN_TIME_DELTA_MS, 50).              % of CPU

%% ------------------------------------------------------------------ running the tests

-spec run(binary(), map()) -> {ok, map()} | {error, integer(), binary(), binary()}.
run(Name, User = #{username := Who}) ->
    case {ana_instance:role(), ana_program:for_execution(Name)} of
        {<<"production">>, _} ->
            {error, 409, <<"NOT_IN_PRODUCTION">>, <<"testes e comparações rodam na instância de desenvolvimento ou de testes, nunca na produção"/utf8>>};
        {_, {ok, #{<<"kind">> := <<"program">>, <<"version">> := V, <<"source">> := Src}}} ->
            case ana_execution:run(Name, #{}, User, #{origin => <<"studio">>, rehearse => true, entry => <<"__list_tests__">>}) of
                {ok, #{result := #{<<"cases">> := Cases, <<"functions">> := Fns}}} ->
                    Tests = [{'case', C} || C <- Cases, is_map(C)] ++ [{function, F} || F <- Fns, is_binary(F)],
                    Results = [one(T, Name, User, undefined) || T <- Tests],
                    Prev = previous_version(Name, V),
                    Regressions = case Prev of
                        undefined -> [];
                        _ -> compare(Results, [one(T, Name, User, Prev) || T <- Tests])
                    end,
                    store(Name, V, Src, Who, Results, Prev, Regressions);
                {ok, _} -> {error, 422, <<"INVALID_TESTS">>, <<"o programa não listou os testes"/utf8>>};
                {error, E} -> {error, 422, maps:get(<<"code">>, E, <<"FAILED">>), maps:get(<<"message">>, E, <<"falhou"/utf8>>)}
            end;
        _ -> {error, 404, <<"PROGRAM_NOT_FOUND">>, <<"programa inexistente"/utf8>>}
    end.

previous_version(Name, V) ->
    case ana_db:one("SELECT max(version) AS v FROM ana_system.program_version WHERE name = $1 AND version < $2", [Name, V]) of
        {ok, #{<<"v">> := P}} when is_integer(P) -> P;
        _ -> undefined
    end.

one({Kind, T}, Name, User, Version) ->
    {Label, Params, Opts} = case Kind of
        'case' -> {maps:get(<<"name">>, T, <<"caso">>), case maps:get(<<"params">>, T, #{}) of P when is_map(P) -> P; _ -> #{} end, #{}};
        function -> {T, #{}, #{entry => T}}
    end,
    Run = maps:merge(Opts, #{origin => <<"studio">>, rehearse => true, coverage => true}),
    R = ana_execution:run(Name, Params, User, case Version of undefined -> Run; _ -> Run#{version => Version} end),
    Base = #{name => Label, kind => Kind},
    case {Kind, R} of
        {_, {ok, #{result := Res} = M}} ->
            Expected = case Kind of 'case' -> maps:get(<<"error">>, T, null); function -> null end,
            {Status, Msg} = case {Expected, Kind} of
                {null, function} -> {passed, null};
                {null, 'case'} ->
                    Expect = maps:get(<<"expect">>, T, null),
                    case Expect =:= null orelse contains(Res, Expect) of
                        true -> {passed, null};
                        false -> {failed, iolist_to_binary([<<"esperava "/utf8>>, json:encode(Expect), <<", veio "/utf8>>,
                                                            json:encode(cut(Res))])}
                    end;
                {Code, _} -> {failed, iolist_to_binary([<<"esperava o erro "/utf8>>, to_bin(Code), <<" e a rotina concluiu"/utf8>>])}
            end,
            Base#{status => Status, message => Msg, metrics => metrics(M), coverage => maps:get(coverage, M, null)};
        {'case', {error, #{<<"code">> := Code} = E}} ->
            case maps:get(<<"error">>, T, null) of
                Code -> Base#{status => passed, message => null, metrics => null, coverage => null};
                _ -> Base#{status => failed, message => <<Code/binary, ": ", (maps:get(<<"message">>, E, <<>>))/binary>>,
                           metrics => null, coverage => null}
            end;
        {_, {error, E}} ->
            Base#{status => failed, message => iolist_to_binary([maps:get(<<"code">>, E, <<"FAILED">>), <<": ">>,
                                                                 maps:get(<<"message">>, E, <<>>)]),
                  metrics => null, coverage => null}
    end.

metrics(M) ->
    U = maps:get(usage, M, #{}),
    #{sql_count => metric(U, sql_count), cpu_ms => metric(U, cpu_ms), rows_read => metric(U, rows_read),
      duration_ms => maps:get(duration_ms, M, null)}.

metric(Map, K) when is_map(Map) -> maps:get(K, Map, maps:get(atom_to_binary(K), Map, null));
metric(_, _) -> null.

%% The result contains what is expected: maps by their keys, lists item by item, numbers by value.
contains(A, E) when is_map(E), is_map(A) ->
    lists:all(fun({K, V}) -> maps:is_key(K, A) andalso contains(maps:get(K, A), V) end, maps:to_list(E));
contains(A, E) when is_list(E), is_list(A), length(A) =:= length(E) ->
    lists:all(fun({X, Y}) -> contains(X, Y) end, lists:zip(A, E));
contains(A, E) when is_number(A), is_number(E) -> A == E;
contains(A, E) when is_binary(A), is_number(E) -> num(A) == E;
contains(A, E) when is_number(A), is_binary(E) -> A == num(E);
contains(A, E) -> A =:= E.

num(B) ->
    try binary_to_float(B) catch _:_ -> try binary_to_integer(B) catch _:_ -> undefined end end.

cut(V) ->
    J = iolist_to_binary(json:encode(V)),
    case byte_size(J) > 300 of true -> <<(binary:part(J, 0, 300))/binary, "…"/utf8>>; false -> V end.

to_bin(B) when is_binary(B) -> B;
to_bin(V) -> iolist_to_binary(json:encode(V)).

%% D5 (CA-064-03): the same test on both versions, both passing — more SQL commands or more time beyond the limits.
compare(New, Old) ->
    SqlPct = ana_settings:get(quality_perf_sql_pct),
    TimePct = ana_settings:get(quality_perf_time_pct),
    OldBy = maps:from_list([{N, M} || #{name := N, status := passed, metrics := M} <- Old, is_map(M)]),
    lists:append([regressions(N, M, maps:get(N, OldBy), SqlPct, TimePct)
                  || #{name := N, status := passed, metrics := M} <- New, is_map(M), maps:is_key(N, OldBy)]).

regressions(Name, New, Old, SqlPct, TimePct) ->
    Worse = fun(K, Pct, Min) ->
        case {maps:get(K, New), maps:get(K, Old)} of
            {A, B} when is_integer(A), is_integer(B), A - B >= Min, A * 100 > B * (100 + Pct) ->
                [#{test => Name, metric => K, previous => B, current => A}];
            _ -> []
        end
    end,
    %% Time is compared by the program's own CPU, not the wall clock (which carries the start of the worker process
    %% and the machine's load, and would cry wolf).
    Worse(sql_count, SqlPct, ?MIN_SQL_DELTA) ++ Worse(cpu_ms, TimePct, ?MIN_TIME_DELTA_MS).

store(Name, V, Src, Who, Results, Prev, Regressions) ->
    Passed = length([x || #{status := passed} <- Results]),
    Failed = length(Results) - Passed,
    Executable = lists:usort(lists:append([maps:get(<<"executable">>, C, []) || #{coverage := C} <- Results, is_map(C)])),
    Executed = lists:usort(lists:append([maps:get(<<"executed">>, C, []) || #{coverage := C} <- Results, is_map(C)])),
    Coverage = case Executable of [] -> null; _ -> round(length(Executed) * 1000 / length(Executable)) / 10 end,
    Sha = ana_transport:item_sha(#{<<"kind">> => <<"program">>, <<"source">> => Src}),
    Lean = [maps:without([coverage], R) || R <- Results],
    {ok, [#{<<"id">> := Id}]} =
        ana_db:rows("INSERT INTO ana_system.program_test_run (program, version, sha256, run_by, passed, failed, executed_lines, "
                    "executable_lines, coverage, results, previous_version, regressions) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, "
                    "$9, $10::text::jsonb, $11, $12::text::jsonb) RETURNING id",
                    [Name, V, Sha, Who, Passed, Failed, length(Executed), length(Executable), Coverage,
                     iolist_to_binary(json:encode(Lean)), case Prev of undefined -> null; _ -> Prev end,
                     iolist_to_binary(json:encode(Regressions))]),
    {ok, #{id => Id, program => Name, version => V, passed => Passed, failed => Failed, coverage => Coverage,
           executed_lines => length(Executed), executable_lines => length(Executable), uncovered => Executable -- Executed,
           results => Lean, previous_version => case Prev of undefined -> null; _ -> Prev end, regressions => Regressions}}.

%% ------------------------------------------------------------------ the gate (D4, D5)

%% Findings of the latest test run of this exact source (same sha): failing tests, performance worsened against the
%% previous version, and — by policy — a program that writes without a passing test.
-spec gate_findings(binary(), binary()) -> [map()].
gate_findings(Name, Sha) ->
    Last = case ana_db:one("SELECT passed, failed, results, regressions FROM ana_system.program_test_run "
                           "WHERE program = $1 AND sha256 = $2 ORDER BY run_at DESC LIMIT 1", [Name, Sha]) of
        {ok, #{} = R} -> R;
        _ -> none
    end,
    Failing = case Last of
        #{<<"failed">> := F, <<"results">> := Rs} when F > 0 ->
            Names = [N || #{<<"name">> := N, <<"status">> := <<"failed">>} <- Rs],
            [finding(<<"tests_failed">>, <<"robustness">>,
                     iolist_to_binary([integer_to_binary(F), <<" teste(s) falhando: "/utf8>>, lists:join(<<", ">>, Names)]),
                     <<"rode os testes na tela Qualidade e corrija o programa ou o teste"/utf8>>, Names)];
        _ -> []
    end,
    Worse = case Last of
        #{<<"regressions">> := Gs} ->
            [finding(<<"performance_regression">>, <<"performance">>,
                     iolist_to_binary([<<"teste "/utf8>>, T, <<": "/utf8>>, metric_label(K), <<" passou de "/utf8>>,
                                       integer_to_binary(B), <<" para "/utf8>>, integer_to_binary(A),
                                       <<" em relação à versão anterior"/utf8>>]),
                     <<"veja o que mudou entre as versões (SQL dentro de laço, leitura sem limite)"/utf8>>, [T, K])
             || #{<<"test">> := T, <<"metric">> := K, <<"previous">> := B, <<"current">> := A} <- Gs];
        _ -> []
    end,
    Missing = case ana_settings:get(quality_tests_required) =:= 1 andalso writes(Name) of
        true when Last =:= none; map_get(<<"passed">>, Last) =:= 0 ->
            [finding(<<"tests_missing">>, <<"robustness">>, <<"programa que grava sem teste passando"/utf8>>,
                     <<"declare TESTS ou funções test_ no programa e rode os testes"/utf8>>, [Name])];
        _ -> []
    end,
    Failing ++ Worse ++ Missing.

metric_label(<<"sql_count">>) -> <<"comandos SQL"/utf8>>;
metric_label(<<"cpu_ms">>) -> <<"CPU (ms)"/utf8>>;
metric_label(K) -> K.

finding(Rule, Category, Message, Suggestion, Parts) ->
    Fp = binary:part(binary:encode_hex(crypto:hash(sha256, iolist_to_binary(json:encode([Rule | Parts]))), lowercase), 0, 16),
    #{<<"line">> => 0, <<"rule">> => Rule, <<"severity">> => <<"serious">>, <<"category">> => Category,
      <<"message">> => Message, <<"suggestion">> => Suggestion, <<"fingerprint">> => Fp}.

writes(Name) ->
    case ana_db:one("SELECT EXISTS (SELECT 1 FROM ana_system.writing_programs() w WHERE w = $1) AS w", [Name]) of
        {ok, #{<<"w">> := true}} -> true;
        _ -> false
    end.

%% ------------------------------------------------------------------ failures by version (D6)

-spec failures(binary()) -> [map()].
failures(Name) ->
    {ok, Groups} = ana_db:rows(
        "SELECT version, error->>'code' AS code, count(*)::int AS n, min(started_at) AS first_seen, max(started_at) AS last_seen, "
        "       (array_agg(error->>'message' ORDER BY started_at DESC))[1] AS message, "
        "       (array_agg(id::text ORDER BY started_at DESC))[1] AS last_execution "
        "FROM ana_system.execution WHERE program = $1 AND status IN ('error', 'timeout') AND started_at > now() - interval '90 days' "
        "GROUP BY version, error->>'code' ORDER BY min(started_at) DESC LIMIT 50", [Name]),
    %% The version a code first appeared in (CA-064-05: "começou na versão X").
    Since = lists:foldl(fun(#{<<"code">> := C, <<"version">> := V}, Acc) ->
                            maps:update_with(C, fun(O) -> min(O, V) end, V, Acc)
                        end, #{}, [G || G = #{<<"version">> := V} <- Groups, is_integer(V)]),
    [G#{<<"started_in">> => maps:get(C, Since, null), <<"package">> => package(Name, V)}
     || G = #{<<"code">> := C, <<"version">> := V} <- Groups].

%% The package that brought this version to this instance, with its gate result for the program.
package(_, null) -> null;
package(Name, V) ->
    case ana_db:one("SELECT t.id, t.title, t.imported_at, t.origin, t.manifest->'quality_gate' AS gate "
                    "FROM ana_system.transport_item i JOIN ana_system.transport t ON t.id = i.transport_id "
                    "WHERE i.kind = 'program' AND i.name = $1 AND i.created_version = $2 AND t.direction = 'in' "
                    "AND t.status IN ('imported', 'reverted') ORDER BY t.imported_at DESC LIMIT 1", [Name, V]) of
        {ok, #{<<"id">> := Id} = T} ->
            Gate = maps:get(<<"gate">>, T, null),
            Mine = case Gate of
                #{<<"programs">> := Ps} -> [P || P = #{<<"name">> := N} <- Ps, N =:= Name];
                _ -> []
            end,
            #{id => Id, title => maps:get(<<"title">>, T), imported_at => maps:get(<<"imported_at">>, T),
              origin => maps:get(<<"origin">>, T),
              gate => case {Gate, Mine} of
                  {null, _} -> null;
                  {#{} = G, [P | _]} -> #{ok => maps:get(<<"ok">>, G, null), checked_at => maps:get(<<"checked_at">>, G, null),
                                          blocking => length(maps:get(<<"blocking">>, P, [])),
                                          exempted => length(maps:get(<<"exempted">>, P, []))};
                  {#{} = G, []} -> #{ok => maps:get(<<"ok">>, G, null), checked_at => maps:get(<<"checked_at">>, G, null)}
              end};
        _ -> null
    end.

%% ------------------------------------------------------------------ the Quality screen (D8)

-spec overview(binary(), map()) -> {ok, map()} | {error, integer(), binary(), binary()}.
overview(Name, _User) ->
    case ana_db:one("SELECT name, version, source, description FROM ana_system.program WHERE name = $1", [Name]) of
        {ok, #{<<"source">> := Src, <<"version">> := V} = P} when is_binary(Src) ->
            {ok, Gate} = ana_quality:gate([Name]),
            Report = case maps:get(programs, Gate) of [R | _] -> R; [] -> null end,
            {ok, Runs} = ana_db:rows("SELECT id, version, run_at, run_by, passed, failed, coverage, executed_lines, executable_lines, "
                                     "results, previous_version, regressions FROM ana_system.program_test_run "
                                     "WHERE program = $1 ORDER BY run_at DESC LIMIT 10", [Name]),
            {ok, Versions} = ana_db:rows("SELECT v.version, v.created_at, v.created_by, v.comment, "
                                         "  (SELECT t.title FROM ana_system.transport_item i JOIN ana_system.transport t ON t.id = i.transport_id "
                                         "    WHERE i.kind = 'program' AND i.name = v.name AND i.created_version = v.version "
                                         "    AND t.direction = 'in' ORDER BY t.imported_at DESC LIMIT 1) AS package "
                                         "FROM ana_system.program_version v WHERE v.name = $1 ORDER BY v.version DESC LIMIT 20", [Name]),
            {ok, #{program => maps:without([<<"source">>], P), version => V, gate => Report, gate_ok => maps:get(ok, Gate),
                   runs => Runs, versions => Versions, failures => failures(Name),
                   in_production => ana_instance:role() =:= <<"production">>}};
        _ -> {error, 404, <<"PROGRAM_NOT_FOUND">>, <<"programa inexistente"/utf8>>}
    end.
