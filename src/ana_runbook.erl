%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Guided runbooks (spec 077, T-077-06, D8, RF-077-07; plan §2.4). A runbook (data) is a sequence of checks, actions
%% of the catalog and instructions. The checks run by themselves; the person only decides. A run goes step by step or
%% "until the next decision", can be paused, resumed and handed to someone else, and keeps the time of each step.
%% Checks are a fixed map of the core (a runbook never runs code): each answers a value and a sentence.
-module(ana_runbook).

-export([list/0, checks/0, start/3, advance/3, pause/2, resume/2, hand_over/3, run/1, open_runs/0]).

%% ------------------------------------------------------------------ the checks (fixed)
-spec checks() -> #{binary() => fun(() -> {ok, term(), binary()} | {unknown, binary()})}.
checks() ->
    #{<<"db_reachable">> => fun() ->
          Up = (catch ana_db:one("SELECT 1 AS ok", [])) =:= {ok, #{<<"ok">> => 1}},
          {ok, Up, case Up of true -> <<"o banco responde"/utf8>>; false -> <<"o banco não responde"/utf8>> end}
      end,
      <<"db_size_mb">> => fun() ->
          case catch ana_db:one("SELECT (pg_database_size(current_database()) / 1048576)::bigint AS mb", []) of
              {ok, #{<<"mb">> := Mb}} -> {ok, Mb, <<"o banco ocupa "/utf8, (integer_to_binary(Mb))/binary, " MiB">>};
              _ -> {unknown, <<"o banco não respondeu"/utf8>>}
          end
      end,
      <<"disk_free_pct">> => fun disk_free/0,
      <<"replica_lag_s">> => fun() ->
          case catch ana_db:one("SELECT COALESCE(max(extract(epoch FROM replay_lag)), 0)::int AS s, count(*)::int AS n "
                                "FROM pg_stat_replication", []) of
              {ok, #{<<"s">> := S, <<"n">> := 0}} -> {ok, S, <<"nenhuma réplica ligada a este primário"/utf8>>};
              {ok, #{<<"s">> := S, <<"n">> := N}} ->
                  {ok, S, unicode:characters_to_binary(io_lib:format("~b réplica(s); maior atraso ~b s", [N, S]))};
              _ -> {unknown, <<"o banco não respondeu"/utf8>>}
          end
      end,
      <<"nodes_ready">> => fun() ->
          N = 1 + length([X || X <- nodes(), case catch erpc:call(X, ana_ha, ready, [], 2000) of {true, _} -> true; _ -> false end]),
          {ok, N, unicode:characters_to_binary(io_lib:format("~b nó(s) pronto(s)", [N]))}
      end,
      <<"python_ready">> => fun() ->
          case catch ana_py_pool:status() of
              #{ready := R} -> {ok, R, unicode:characters_to_binary(io_lib:format("~b processo(s) Python prontos", [R]))};
              _ -> {unknown, <<"o pool de Python não respondeu"/utf8>>}
          end
      end,
      <<"health_not_green">> => fun() ->
          case catch ana_health:state() of
              St when is_map(St) ->
                  Bad = [C || {C, #{state := S}} <- maps:to_list(St), S =/= green],
                  {ok, length(Bad), case Bad of
                                        [] -> <<"todos os componentes verdes">>;
                                        _ -> <<"fora do verde: "/utf8, (iolist_to_binary(lists:join(<<", ">>, [to_bin(C) || C <- Bad])))/binary>>
                                    end};
              _ -> {unknown, <<"a saúde não respondeu"/utf8>>}
          end
      end,
      <<"restarts_last_hour">> => fun() ->
          N = case catch gen_server:call(ana_core_view, restarts, 2000) of L when is_list(L) -> length(L); _ -> 0 end,
          {ok, N, unicode:characters_to_binary(io_lib:format("~b queda(s) de subsistema na última hora", [N]))}
      end,
      <<"license_days_left">> => fun() ->
          case catch ana_license:current() of
              #{days_left := D} when is_integer(D) -> {ok, D, unicode:characters_to_binary(io_lib:format("~b dia(s) até a licença vencer", [D]))};
              #{} -> {ok, 99999, <<"licença sem vencimento"/utf8>>};
              _ -> {unknown, <<"a licença não respondeu"/utf8>>}
          end
      end,
      <<"queue_stuck">> => fun() ->
          case catch ana_db:one("SELECT (SELECT count(*) FROM integration.outbox WHERE status IN ('pending', 'processing') "
                                "  AND created_at < now() - interval '15 minutes') + "
                                "(SELECT count(*) FROM integration.inbox WHERE status IN ('pending', 'processing') "
                                "  AND created_at < now() - interval '15 minutes') AS n", []) of
              {ok, #{<<"n">> := N}} -> {ok, N, unicode:characters_to_binary(io_lib:format("~b mensagem(ns) parada(s) há mais de 15 min", [N]))};
              _ -> {unknown, <<"o banco não respondeu"/utf8>>}
          end
      end}.

%% The node's own file system (os_mon's disksup, when running); otherwise the person checks (never a guess).
disk_free() ->
    %% os_mon may not run on this node: called by name, never a hard dependency of the release.
    Disksup = disksup,
    case catch Disksup:get_disk_data() of
        [_ | _] = Disks ->
            Dir = ana_config:text("ANA_FILES_DIR", "/"),
            Best = lists:foldl(fun({Mount, _, _} = D, Acc) ->
                                   case lists:prefix(Mount, Dir) andalso length(Mount) >= length(element(1, Acc)) of
                                       true -> D;
                                       false -> Acc
                                   end
                               end, {"", 0, 0}, Disks),
            case Best of
                {"", _, _} -> {unknown, <<"não foi possível ler o disco deste nó (use ana-ctl disk)"/utf8>>};
                {M, _Kb, UsedPct} ->
                    Free = 100 - UsedPct,
                    {ok, Free, unicode:characters_to_binary(io_lib:format("~b% livre em ~ts", [Free, M]))}
            end;
        _ -> {unknown, <<"a medição do disco não está ligada neste nó: confira com ana-ctl disk"/utf8>>}
    end.

to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(B) when is_binary(B) -> B;
to_bin(X) -> unicode:characters_to_binary(io_lib:format("~0p", [X])).

%% ------------------------------------------------------------------ catalog
-spec list() -> {ok, [map()]}.
list() ->
    {ok, Rows} = ana_db:rows("SELECT DISTINCT ON (code) code, version, name, when_to_use, steps, product "
                             "FROM technical.runbook WHERE active ORDER BY code, version DESC", []),
    {ok, [R#{<<"steps">> => decode(S)} || R = #{<<"steps">> := S} <- Rows]}.

-spec open_runs() -> {ok, [map()]}.
open_runs() ->
    {ok, Rows} = ana_db:rows("SELECT r.id, r.code, b.name, r.status, r.step, r.owner, r.started_at "
                             "FROM technical.runbook_run r JOIN technical.runbook b ON b.code = r.code AND b.version = r.version "
                             "WHERE r.status IN ('running', 'paused', 'waiting') ORDER BY r.id", []),
    {ok, Rows}.

-spec run(integer()) -> {ok, map()} | {error, not_found}.
run(Id) ->
    case ana_db:one("SELECT r.id, r.code, r.version, b.name, b.steps, r.status, r.step, r.owner, r.started_by, r.started_at, "
                    "  r.finished_at, r.pending_action, r.log "
                    "FROM technical.runbook_run r JOIN technical.runbook b ON b.code = r.code AND b.version = r.version "
                    "WHERE r.id = $1", [Id]) of
        {ok, #{<<"steps">> := S, <<"log">> := L} = R} -> {ok, R#{<<"steps">> => decode(S), <<"log">> => decode(L)}};
        _ -> {error, not_found}
    end.

%% ------------------------------------------------------------------ running
%% Starts the latest version of a runbook and goes until the first decision.
-spec start(binary(), map(), map()) -> {ok, map()} | {error, term()}.
start(Code, User = #{username := Who}, Opts) ->
    case ana_db:one("SELECT version FROM technical.runbook WHERE code = $1 AND active ORDER BY version DESC LIMIT 1", [Code]) of
        {ok, #{<<"version">> := V}} ->
            {ok, #{<<"id">> := Id}} = ana_db:one("INSERT INTO technical.runbook_run (code, version, owner, started_by) "
                                                 "VALUES ($1, $2, $3, $3) RETURNING id", [Code, V, Who]),
            ana_admin:log(Who, <<"runbook.start">>, Code, null, #{run => Id}),
            advance(Id, User, Opts);
        _ -> {error, <<"roteiro inexistente"/utf8>>}
    end.

%% Decision: confirm (do the action or the instruction of the current step) | step (one step only, no decision).
-spec advance(integer(), map(), map()) -> {ok, map()} | {error, term()}.
advance(Id, User = #{username := Who}, Opts) ->
    case run(Id) of
        {error, not_found} -> {error, <<"execução de roteiro inexistente"/utf8>>};
        {ok, #{<<"owner">> := Owner}} when Owner =/= Who ->
            {error, <<"quem conduz este roteiro agora é "/utf8, Owner/binary, ": peça que ele o entregue a você"/utf8>>};
        {ok, #{<<"status">> := S}} when S =:= <<"done">>; S =:= <<"stopped">> ->
            {error, <<"este roteiro já terminou"/utf8>>};
        {ok, #{<<"status">> := <<"paused">>}} -> {error, <<"o roteiro está pausado: retome antes"/utf8>>};
        {ok, R} -> loop(R, User, maps:get(confirm, Opts, false), maps:get(step, Opts, false))
    end.

loop(R = #{<<"id">> := Id, <<"steps">> := Steps, <<"step">> := N}, _User, _Confirm, _One) when N > length(Steps) ->
    finish(Id, <<"done">>, R);
loop(R = #{<<"id">> := Id, <<"steps">> := Steps, <<"step">> := N, <<"status">> := Status}, User, Confirm, One) ->
    Step = lists:nth(N, Steps),
    Started = erlang:monotonic_time(millisecond),
    case {maps:get(<<"kind">>, Step), Status} of
        {_, <<"waiting">>} -> waiting(R, Step, User);
        {<<"check">>, _} ->
            {Ok, Value, Text} = check(Step),
            log(Id, N, Step, Ok, Value, Text, Started),
            next(R, Step, Ok, User, false, One);
        {Kind, _} when not Confirm ->
            %% An action or an instruction: the person decides.
            {ok, R2} = run(Id),
            {ok, R2#{<<"waiting_for">> => Kind, <<"current">> => Step}};
        {<<"instruction">>, _} ->
            log(Id, N, Step, true, null, <<"feito"/utf8>>, Started),
            next(R, Step, true, User, false, One);
        {<<"action">>, _} ->
            Params = maps:get(<<"params">>, Step, #{}),
            case ana_tech:run(maps:get(<<"action">>, Step), Params, User, #{confirmed => true, origin => <<"runbook">>,
                                                                           reason => <<"roteiro "/utf8, (maps:get(<<"code">>, R))/binary>>}) of
                {ok, Run} ->
                    log(Id, N, Step, true, maps:get(<<"id">>, Run), <<"ação executada"/utf8>>, Started),
                    next(R, Step, true, User, false, One);
                {pending, Run} ->
                    log(Id, N, Step, null, maps:get(<<"id">>, Run), <<"aguarda a aprovação de outra pessoa"/utf8>>, Started),
                    {ok, _} = ana_db:exec("UPDATE technical.runbook_run SET status = 'waiting', pending_action = $2 WHERE id = $1",
                                          [Id, maps:get(<<"id">>, Run)]),
                    run(Id);
                {error, _, M} ->
                    log(Id, N, Step, false, null, M, Started),
                    next(R, Step, false, User, false, One)
            end
    end.

%% A high-risk action decided by the second person: done goes on; refused or expired follows "if it fails".
waiting(R = #{<<"id">> := Id, <<"pending_action">> := A, <<"step">> := N}, Step, User) ->
    {ok, #{<<"status">> := S}} = ana_db:one("SELECT status FROM technical.action_run WHERE id = $1", [A]),
    case S of
        <<"pending">> -> {ok, (element(2, run(Id)))#{<<"waiting_for">> => <<"approval">>}};
        _ ->
            Ok = S =:= <<"done">> orelse S =:= <<"review">>,
            log(Id, N, Step, Ok, A, <<"decisão da segunda pessoa: "/utf8, S/binary>>, erlang:monotonic_time(millisecond)),
            {ok, _} = ana_db:exec("UPDATE technical.runbook_run SET status = 'running', pending_action = NULL WHERE id = $1", [Id]),
            next(R#{<<"status">> => <<"running">>}, Step, Ok, User, false, false)
    end.

next(R = #{<<"id">> := Id, <<"step">> := N}, Step, Ok, User, Confirm, One) ->
    Target = case {Ok, maps:get(<<"on_fail">>, Step, <<"stop">>)} of
        {true, _} -> N + 1;
        {_, #{<<"goto">> := G}} when is_integer(G) -> G;
        {_, _} -> stop
    end,
    case Target of
        stop -> finish(Id, <<"stopped">>, R);
        _ ->
            {ok, _} = ana_db:exec("UPDATE technical.runbook_run SET step = $2 WHERE id = $1", [Id, Target]),
            {ok, R2} = run(Id),
            case One of
                true -> {ok, R2};
                false -> loop(R2, User, Confirm, false)
            end
    end.

finish(Id, Status, _R) ->
    {ok, _} = ana_db:exec("UPDATE technical.runbook_run SET status = $2, finished_at = now() WHERE id = $1", [Id, Status]),
    run(Id).

check(Step) ->
    Code = maps:get(<<"check">>, Step),
    case maps:find(Code, checks()) of
        error -> {false, null, <<"verificação desconhecida: "/utf8, Code/binary>>};
        {ok, F} ->
            case catch F() of
                {ok, V, Text} -> {expect(maps:get(<<"expect">>, Step, null), V), V, Text};
                {unknown, Text} -> {false, null, Text};
                Other -> {false, null, to_bin(Other)}
            end
    end.

expect(null, _) -> true;
expect(#{<<"op">> := Op, <<"value">> := W}, V) ->
    case Op of
        <<"=">> -> V =:= W;
        <<"<">> -> is_number(V) andalso V < W;
        <<"<=">> -> is_number(V) andalso V =< W;
        <<">">> -> is_number(V) andalso V > W;
        <<">=">> -> is_number(V) andalso V >= W;
        _ -> false
    end.

log(Id, N, Step, Ok, Value, Text, Started) ->
    Entry = #{step => N, kind => maps:get(<<"kind">>, Step), text => maps:get(<<"text">>, Step), ok => Ok, value => Value,
              result => Text, ms => erlang:monotonic_time(millisecond) - Started,
              at => calendar:system_time_to_rfc3339(erlang:system_time(second))},
    {ok, _} = ana_db:exec("UPDATE technical.runbook_run SET log = log || $2::text::jsonb WHERE id = $1",
                          [Id, iolist_to_binary(json:encode([Entry]))]),
    ok.

-spec pause(integer(), map()) -> {ok, map()} | {error, term()}.
pause(Id, #{username := Who}) ->
    set_status(Id, Who, <<"running">>, <<"paused">>).

-spec resume(integer(), map()) -> {ok, map()} | {error, term()}.
resume(Id, #{username := Who}) ->
    set_status(Id, Who, <<"paused">>, <<"running">>).

set_status(Id, Who, From, To) ->
    case ana_db:exec("UPDATE technical.runbook_run SET status = $3 WHERE id = $1 AND owner = $2 AND status = $4",
                     [Id, Who, To, From]) of
        {ok, 1} -> run(Id);
        _ -> {error, <<"só quem conduz o roteiro pausa e retoma, e só no estado certo"/utf8>>}
    end.

%% Handing over: the one conducting it (or an administrator) passes it to another person.
-spec hand_over(integer(), binary(), map()) -> {ok, map()} | {error, term()}.
hand_over(Id, To, #{username := Who, role := Role}) ->
    case ana_db:exec("UPDATE technical.runbook_run r SET owner = $2 WHERE id = $1 AND (owner = $3 OR $4) "
                     "AND status IN ('running', 'paused', 'waiting') "
                     "AND EXISTS (SELECT 1 FROM ana_system.app_user u WHERE u.username = $2 AND u.active)",
                     [Id, To, Who, Role =:= <<"admin">>]) of
        {ok, 1} ->
            ana_admin:log(Who, <<"runbook.hand_over">>, integer_to_binary(Id), Who, To),
            run(Id);
        _ -> {error, <<"não foi possível entregar: confira quem conduz, a situação e o usuário"/utf8>>}
    end.

decode(V) when is_binary(V) -> json:decode(V);
decode(V) -> V.
