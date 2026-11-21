%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% The single process engine (spec 039, RF-039-11..14; runs the esteiras of spec 030 too).
%%
%% Only the scheduler leader works. Each cycle:
%%   1. advances the cases with finished tasks — in one transaction under a lock of the case:
%%      tokens move along the published model (ana_bpm_model), new tasks are created, joins wait
%%      while another branch of the case can still reach them, rule tasks and facts already true are
%%      applied at once, and the case ends when no token is left;
%%   2. claims automatic work with a lease (FOR UPDATE SKIP LOCKED) — BPM tasks (programs, timers,
%%      subprocesses) and esteira steps — and runs it as the process robot (P14). Technical failures
%%      are retried with backoff; a business refusal follows the model's error path or stops the case;
%%   3. sweeps every 30 s: facts of the ERP that complete waiting tasks, deadlines (warning and
%%      escalation in working hours), finished subprocesses, cancelled documents, and the esteiras.
%% People complete tasks through programs (bpm.task_action), which only mark the task as done:
%% navigation happens here, in a single place.
-module(ana_bpm).
-behaviour(gen_server).

-export([start_link/0, on_notify/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TICK_MS, 5000).
-define(MAX_RUNNING, 8).
-define(LEASE, "interval '15 minutes'").
-define(MAX_LOOP, 200).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ana_listener: a case or an esteira moved (channels ana_bpm, ana_flow) — work now.
on_notify(_Channel, _Payload) ->
    gen_server:cast(?MODULE, wake).

init([]) ->
    erlang:send_after(?TICK_MS, self(), tick),
    %% Monotonic time may be negative: the first sweep is due right away, whatever its origin.
    {ok, #{running => 0, last_sweep => erlang:monotonic_time(millisecond) - 3600000, sweep => undefined,
           advance => undefined, again => false}}.

handle_call(_, _From, S) -> {reply, {error, unknown}, S}.

handle_cast(wake, S) -> {noreply, work(S#{again := true})};
handle_cast(_, S) -> {noreply, S}.

handle_info(tick, S) ->
    erlang:send_after(?TICK_MS, self(), tick),
    {noreply, work(S)};
handle_info({'DOWN', Ref, process, _, _}, S = #{sweep := Ref}) -> {noreply, S#{sweep := undefined}};
handle_info({'DOWN', Ref, process, _, _}, S = #{advance := Ref, again := Again}) ->
    S2 = S#{advance := undefined},
    {noreply, case Again of true -> work(S2); false -> S2 end};
handle_info({'DOWN', _, process, _, _}, S = #{running := N}) -> {noreply, work(S#{running := max(0, N - 1)})};
handle_info(_, S) -> {noreply, S}.

work(S = #{running := N, last_sweep := Last, sweep := Sweep, advance := Adv}) ->
    case leader() of
        false -> S;
        true ->
            S1 = case Adv of
                undefined -> {_, R} = spawn_monitor(fun advance_all/0), S#{advance := R, again := false};
                _ -> S
            end,
            Free = ?MAX_RUNNING - N,
            Tasks = case Free > 0 of true -> claim(Free); false -> [] end,
            Steps = case Free - length(Tasks) of F when F > 0 -> ana_flows:claim(F); _ -> [] end,
            _ = [spawn_monitor(fun() -> run_task(T) end) || T <- Tasks],
            _ = [spawn_monitor(fun() -> ana_flows:step(St) end) || St <- Steps],
            S2 = S1#{running := N + length(Tasks) + length(Steps)},
            Now = erlang:monotonic_time(millisecond),
            case Sweep =:= undefined andalso Now - Last >= sweep_ms() of
                true -> {_, Ref} = spawn_monitor(fun sweep/0), S2#{last_sweep := Now, sweep := Ref};
                false -> S2
            end
    end.

%% Facts, deadlines and subprocesses are checked every ANA_BPM_SWEEP_MS (default 30 s).
sweep_ms() -> max(1000, ana_config:integer("ANA_BPM_SWEEP_MS", 30000)).

leader() ->
    case catch ana_scheduler:status() of
        #{leader := true} -> true;
        _ -> false
    end.

%% ---------------------------------------------------------------- 1. advance cases

advance_all() ->
    case ana_db:rows("SELECT DISTINCT case_id FROM bpm.task WHERE status IN ('done', 'failed') AND NOT advanced "
                     "ORDER BY case_id LIMIT 200", []) of
        {ok, Rows} ->
            lists:foreach(fun(#{<<"case_id">> := Id}) ->
                try advance(Id)
                catch C:R:St -> logger:error("bpm: case ~p could not advance: ~0p:~0p ~0p", [Id, C, R, St])
                end
            end, Rows);
        {error, E} -> logger:warning("bpm: advance query failed: ~0p", [E])
    end.

advance(Id) ->
    {ok, _} = ana_db:transaction(fun(C) ->
        {ok, Rows} = ana_db:rows(C,
            "SELECT c.id, c.status, c.doc_entity, c.doc_key, c.data, c.parent_task, c.process_code, c.title, v.model, v.compiled, "
            "  d.facts_sql FROM bpm.case c JOIN bpm.version v ON v.process_code = c.process_code AND v.version = c.version "
            "JOIN bpm.document d ON d.entity = c.doc_entity WHERE c.id = $1 FOR UPDATE OF c", [Id]),
        case Rows of
            [#{<<"status">> := St}] when St =:= <<"done">>; St =:= <<"cancelled">> ->
                {ok, _} = ana_db:query(C, "UPDATE bpm.task SET advanced = true WHERE case_id = $1 AND NOT advanced", [Id]),
                {ok, done};
            [Case] ->
                Facts = facts(C, Case),
                Vars = maps:remove(<<"doc">>, maps:get(<<"data">>, Case)),
                {Vars2, Failed} = loop(C, Case, Facts, Vars, false, ?MAX_LOOP),
                finish_case(C, Case, Facts, Vars2, Failed),
                {ok, done};
            [] -> {ok, done}
        end
    end),
    ok.

facts(C, #{<<"facts_sql">> := Sql, <<"doc_key">> := Key}) when is_binary(Key) ->
    case ana_db:rows(C, Sql, [Key]) of
        {ok, [Row | _]} -> Row#{<<"key">> => Key};
        _ -> #{<<"key">> => Key}
    end;
facts(_, _) -> #{}.

eval(Facts, Vars) -> maps:merge(Facts, Vars).

loop(_, _, _, Vars, Failed, 0) -> {Vars, Failed};
loop(C, Case = #{<<"id">> := Id, <<"model">> := Model}, Facts, Vars, Failed, N) ->
    {ok, Done} = ana_db:rows(C,
        "SELECT id, token_id, node, kind, name, status, outcome, result, error, how FROM bpm.task "
        "WHERE case_id = $1 AND status IN ('done', 'failed') AND NOT advanced ORDER BY id", [Id]),
    case Done of
        [] ->
            case retry_joins(C, Case, Facts, Vars) of
                false -> {Vars, Failed};
                true -> loop(C, Case, Facts, Vars, Failed, N - 1)
            end;
        _ ->
            {V2, F2} = lists:foldl(fun(T, {V, F}) -> finished(C, Case, Model, Facts, V, F, T) end, {Vars, Failed}, Done),
            loop(C, Case, Facts, V2, F2, N - 1)
    end.

finished(C, #{<<"id">> := Id} = Case, Model, Facts, Vars, Failed, T = #{<<"id">> := TId, <<"node">> := Node}) ->
    {ok, _} = ana_db:query(C, "UPDATE bpm.task SET advanced = true WHERE id = $1", [TId]),
    case T of
        #{<<"status">> := <<"failed">>, <<"error">> := Err} ->
            event(C, Id, Node, <<"fail">>, null, Err),
            {Vars, true};
        #{<<"token_id">> := Tok, <<"kind">> := Kind, <<"outcome">> := Outcome0, <<"result">> := Result} ->
            {ok, _} = ana_db:query(C, "UPDATE bpm.token SET status = 'done' WHERE id = $1", [Tok]),
            %% People's completions are logged by bpm.task_action; the rest is logged here.
            case {maps:get(<<"how">>, T), maps:get(<<"name">>, T)} of
                {<<"manual">>, _} -> ok;
                {_, N} when Kind =:= <<"rule">>, (N =:= <<"Início"/utf8>> orelse N =:= <<"Junção"/utf8>>) -> ok;
                {How, _} -> event(C, Id, Node, <<"done">>, null, #{<<"how">> => How, <<"outcome">> => Outcome0})
            end,
            Vars1 = case {Kind, Result} of
                {<<"rule">>, R} when is_map(R) -> maps:merge(Vars, R);
                {K, #{<<"vars">> := VarsIn} = R} when (K =:= <<"human">> orelse K =:= <<"approval">>), is_map(VarsIn) ->
                    (maps:merge(Vars, VarsIn))#{Node => maps:remove(<<"vars">>, R)};
                {_, null} -> Vars;
                {_, R} -> Vars#{Node => R}
            end,
            Outcome = case Outcome0 of null -> <<"done">>; O -> O end,
            Vars2 = case Kind of
                <<"approval">> -> Vars1#{<<Node/binary, "_decision">> => Outcome};
                _ when Outcome =:= <<"error">> -> Vars1#{<<"_error">> => error_text(T)};
                _ -> Vars1
            end,
            Nav = case Outcome of
                <<"error">> -> <<"error">>;
                <<"timeout">> -> <<"timeout">>;
                _ -> <<"done">>
            end,
            case ana_bpm_model:next(Model, Node, eval(Facts, Vars2), Nav) of
                {ok, Targets} ->
                    lists:foldl(fun(To, {V, F}) -> enter(C, Case, Model, Facts, V, F, To) end, {Vars2, Failed}, Targets);
                {error, Msg} ->
                    stop(C, Id, Node, Msg),
                    {Vars2, true}
            end
    end.

error_text(#{<<"error">> := #{<<"message">> := M}}) -> M;
error_text(_) -> <<"erro">>.

stop(C, Id, Node, Msg) ->
    event(C, Id, Node, <<"error">>, null, #{<<"message">> => Msg}),
    {ok, _} = ana_db:query(C, "UPDATE bpm.case SET reason = $2 WHERE id = $1", [Id, Msg]),
    ok.

%% A token arrives at a node.
enter(C, #{<<"id">> := Id} = Case, Model, Facts, Vars, Failed, NodeId) ->
    case ana_bpm_model:node(Model, NodeId) of
        undefined ->
            stop(C, Id, NodeId, <<"elemento inexistente no modelo">>),
            {Vars, true};
        #{<<"type">> := <<"end">>} ->
            {ok, _} = ana_db:query(C, "INSERT INTO bpm.token (case_id, node, status) VALUES ($1, $2, 'done')", [Id, NodeId]),
            event(C, Id, NodeId, <<"end">>, null, null),
            {Vars, Failed};
        #{<<"type">> := <<"gw_", _/binary>>} ->
            case ana_bpm_model:is_join(Model, NodeId) of
                true ->
                    {ok, _} = ana_db:query(C, "INSERT INTO bpm.token (case_id, node, status) VALUES ($1, $2, 'joining')", [Id, NodeId]),
                    try_join(C, Case, Model, Facts, Vars, Failed, NodeId);
                false -> pass(C, Case, Model, Facts, Vars, Failed, NodeId)
            end;
        #{<<"type">> := Type} = Node ->
            case ana_bpm_model:kind(Type) of
                undefined -> pass(C, Case, Model, Facts, Vars, Failed, NodeId);    % start, annotation…
                Kind -> {create_task(C, Case, Facts, Vars, Node, Kind), Failed}
            end
    end.

%% Through a node that does no work (split gateway, start…).
pass(C, #{<<"id">> := Id} = Case, Model, Facts, Vars, Failed, NodeId) ->
    event(C, Id, NodeId, <<"enter">>, null, null),
    case ana_bpm_model:next(Model, NodeId, eval(Facts, Vars), <<"done">>) of
        {ok, Targets} -> lists:foldl(fun(To, {V, F}) -> enter(C, Case, Model, Facts, V, F, To) end, {Vars, Failed}, Targets);
        {error, Msg} -> stop(C, Id, NodeId, Msg), {Vars, true}
    end.

%% A join waits while another token of the case can still reach it (reachability computed at
%% publication); then the tokens waiting there become one and the case goes on.
try_join(C, #{<<"id">> := Id, <<"compiled">> := Comp} = Case, Model, Facts, Vars, Failed, NodeId) ->
    Reach = maps:get(<<"reach">>, Comp, #{}),
    {ok, Others} = ana_db:rows(C, "SELECT node FROM bpm.token WHERE case_id = $1 AND status IN ('active', 'joining') AND node <> $2",
                               [Id, NodeId]),
    Blocking = [N || #{<<"node">> := N} <- Others, lists:member(NodeId, maps:get(N, Reach, []))],
    case Blocking of
        [] ->
            {ok, _} = ana_db:query(C, "UPDATE bpm.token SET status = 'done' WHERE case_id = $1 AND node = $2 AND status = 'joining'",
                                   [Id, NodeId]),
            pass(C, Case, Model, Facts, Vars, Failed, NodeId);
        _ ->
            event(C, Id, NodeId, <<"wait">>, null, #{<<"waiting_for">> => lists:usort(Blocking)}),
            {Vars, Failed}
    end.

%% Joins whose blocking branches ended elsewhere (an exclusive gateway took another path).
retry_joins(C, #{<<"id">> := Id, <<"compiled">> := Comp}, _Facts, _Vars) ->
    {ok, Js} = ana_db:rows(C, "SELECT DISTINCT node FROM bpm.token WHERE case_id = $1 AND status = 'joining'", [Id]),
    Reach = maps:get(<<"reach">>, Comp, #{}),
    Ready = [J || #{<<"node">> := J} <- Js, not blocked(C, Id, J, Reach)],
    case Ready of
        [] -> false;
        [J | _] ->
            {ok, _} = ana_db:query(C, "UPDATE bpm.token SET status = 'done' WHERE case_id = $1 AND node = $2 AND status = 'joining'",
                                   [Id, J]),
            %% A synthetic finished task keeps the single path of navigation (and the trail).
            {ok, [#{<<"id">> := Tok}]} = ana_db:rows(C, "INSERT INTO bpm.token (case_id, node, status) VALUES ($1, $2, 'active') "
                                                        "RETURNING id", [Id, J]),
            {ok, _} = ana_db:query(C, <<"INSERT INTO bpm.task (case_id, token_id, node, kind, name, status, how, finished_at) "
                                        "VALUES ($1, $2, $3, 'rule', 'Junção', 'done', 'auto', now())"/utf8>>, [Id, Tok, J]),
            true
    end.

blocked(C, Id, J, Reach) ->
    {ok, Others} = ana_db:rows(C, "SELECT node FROM bpm.token WHERE case_id = $1 AND status IN ('active', 'joining') AND node <> $2",
                               [Id, J]),
    lists:any(fun(#{<<"node">> := N}) -> lists:member(J, maps:get(N, Reach, [])) end, Others).

create_task(C, #{<<"id">> := Id, <<"doc_key">> := Key, <<"title">> := Title, <<"model">> := Model}, Facts, Vars, Node, Kind) ->
    #{<<"id">> := NodeId} = Node,
    Name = maps:get(<<"name">>, Node, NodeId),
    P = case maps:get(<<"props">>, Node, #{}) of M when is_map(M) -> M; _ -> #{} end,
    Eval = eval(Facts, Vars),
    {ok, [#{<<"id">> := Tok}]} = ana_db:rows(C, "INSERT INTO bpm.token (case_id, node) VALUES ($1, $2) RETURNING id", [Id, NodeId]),
    event(C, Id, NodeId, <<"enter">>, null, null),
    Sla = num(maps:get(<<"sla_hours">>, P, 0)),
    Warn = num(maps:get(<<"warn_hours">>, P, 0)),
    Fact = case {Kind, maps:get(<<"fact">>, P, null), maps:get(<<"done_fact">>, P, null)} of
        {<<"fact">>, F, _} when is_binary(F), F =/= <<>> -> F;
        {_, _, F} when is_binary(F), F =/= <<>>, Kind =/= <<"auto">> -> F;
        _ -> null
    end,
    %% A person's task without its own responsible takes the role or group of its lane.
    Lane = case [L || L = #{<<"id">> := LId} <- maps:get(<<"lanes">>, Model, []), LId =:= maps:get(<<"lane">>, Node, null)] of
        [L1 | _] -> L1;
        [] -> #{}
    end,
    Own = fun(K) -> case maps:get(K, P, null) of V when is_binary(V), V =/= <<>> -> V; _ -> null end end,
    P2 = case {Own(<<"assignee">>), Own(<<"role">>), Own(<<"group">>)} of
        {null, null, null} -> P#{<<"role">> => maps:get(<<"role">>, Lane, null), <<"group">> => maps:get(<<"group">>, Lane, null)};
        _ -> P
    end,
    Text = fun(K) -> case ana_flows:render(maps:get(K, P2, null), Eval) of B when is_binary(B), B =/= <<>> -> B; _ -> null end end,
    {Status, NextAt, Result, Done} = case Kind of
        <<"rule">> -> {<<"done">>, null, ana_bpm_model:rule_assign(maps:get(<<"assign">>, P, []), Eval), true};
        <<"auto">> -> {<<"ready">>, now, null, false};
        <<"send">> -> {<<"ready">>, now, null, false};
        <<"subprocess">> -> {<<"ready">>, now, null, false};
        <<"timer">> -> {<<"ready">>, {hours, num(maps:get(<<"hours">>, P, 0))}, null, false};
        _ -> {<<"waiting">>, null, null, false}
    end,
    Program = case Kind of
        <<"subprocess">> -> maps:get(<<"process">>, P, null);
        _ -> maps:get(<<"program">>, P, null)
    end,
    Params = case Kind of
        K2 when K2 =:= <<"auto">>; K2 =:= <<"send">> -> maps:get(<<"params">>, P, #{});      % rendered when it runs
        _ -> ana_flows:render(maps:get(<<"params">>, P, #{}), Eval)
    end,
    {ok, [#{<<"id">> := TaskId}]} = ana_db:rows(C,
        "INSERT INTO bpm.task (case_id, token_id, node, kind, name, status, assignee, role, group_name, program, params, "
        "  instructions, priority, due_at, warn_at, next_at, fact, escalate, result, how, finished_at) "
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, "
        "  CASE WHEN $14::numeric > 0 THEN bpm.business_add(now(), $14::numeric) END, "
        "  CASE WHEN $14::numeric > 0 AND $15::numeric > 0 THEN bpm.business_add(now(), greatest($14::numeric - $15::numeric, 0)) END, "
        "  CASE $16::text WHEN 'now' THEN now() WHEN 'hours' THEN now() + make_interval(secs => ($17::numeric * 3600)::int) END, "
        "  $18, $19, $20, CASE WHEN $21 THEN 'auto' END, CASE WHEN $21 THEN now() END) RETURNING id",
        [Id, Tok, NodeId, Kind, Name, Status, Text(<<"assignee">>), Text(<<"role">>), Text(<<"group">>), Program, Params,
         maps:get(<<"instructions">>, P, <<>>), prio(maps:get(<<"priority">>, P, 3)), Sla, Warn,
         case NextAt of now -> <<"now">>; {hours, _} -> <<"hours">>; _ -> null end,
         case NextAt of {hours, H} -> H; _ -> 0 end,
         Fact, maps:get(<<"escalate">>, P, null), Result, Done]),
    case {Kind, Fact} of
        {_, F2} when is_binary(F2), Key =/= null -> complete_if_fact(C, TaskId, F2, Key);
        _ -> ok
    end,
    case Status of
        <<"waiting">> when Kind =:= <<"human">>; Kind =:= <<"approval">> ->
            notify(C, TaskId, Id, <<"task">>, <<"Nova tarefa: "/utf8, Name/binary, " — "/utf8, Title/binary>>);
        _ -> ok
    end,
    Vars.

prio(N) when is_integer(N), N >= 1, N =< 5 -> N;
prio(_) -> 3.

num(N) when is_number(N) -> N;
num(B) when is_binary(B) -> case catch binary_to_integer(B) of I when is_integer(I) -> I; _ -> case catch binary_to_float(B) of F when is_float(F) -> F; _ -> 0 end end;
num(_) -> 0.

complete_if_fact(C, TaskId, Fact, Key) ->
    case ana_db:rows(C, "SELECT sql FROM bpm.fact WHERE code = $1", [Fact]) of
        {ok, [#{<<"sql">> := Sql}]} ->
            %% Same rule as the esteiras: the fact happened when its query returns a true column.
            case ana_db:rows(C, Sql, [Key]) of
                {ok, [Row | _]} ->
                    case lists:member(true, maps:values(Row)) of
                        true ->
                            {ok, _} = ana_db:query(C, "UPDATE bpm.task SET status = 'done', how = 'outside', finished_at = now() "
                                                      "WHERE id = $1 AND status = 'waiting'", [TaskId]),
                            ok;
                        false -> ok
                    end;
                _ -> ok
            end;
        _ -> ok
    end.

finish_case(C, #{<<"id">> := Id, <<"parent_task">> := Parent}, Facts, Vars, Failed) ->
    {ok, [#{<<"open">> := Open, <<"failed">> := Bad, <<"busy">> := Busy}]} = ana_db:rows(C,
        "SELECT (SELECT count(*) FROM bpm.token WHERE case_id = $1 AND status IN ('active', 'joining')) AS open, "
        "  (SELECT count(*) FROM bpm.task WHERE case_id = $1 AND status = 'failed') AS failed, "
        "  (SELECT count(*) FROM bpm.task WHERE case_id = $1 AND status IN ('ready', 'running')) AS busy", [Id]),
    Data = Vars#{<<"doc">> => Facts},
    Status = if
        Failed orelse Bad > 0 -> <<"failed">>;
        Open =:= 0 -> <<"done">>;
        Busy > 0 -> <<"running">>;
        true -> <<"waiting">>
    end,
    {ok, _} = ana_db:query(C, "UPDATE bpm.case SET status = $2, data = $3, updated_at = now(), "
                              "  finished_at = CASE WHEN $2 = 'done' THEN now() END WHERE id = $1", [Id, Status, Data]),
    case {Status, Parent} of
        {<<"done">>, P} when is_integer(P) ->
            {ok, _} = ana_db:query(C, "UPDATE bpm.task SET status = 'done', how = 'auto', result = $2, finished_at = now() "
                                      "WHERE id = $1 AND status = 'waiting'", [P, Vars]),
            ok;
        _ -> ok
    end,
    ok.

event(C, Case, Node, Kind, By, Detail) ->
    {ok, _} = ana_db:query(C, "INSERT INTO bpm.event (case_id, node, kind, by, detail) VALUES ($1, $2, $3, $4, $5)",
                           [Case, Node, Kind, By, Detail]),
    ok.

%% People who should know about a task: its assignee, else everyone with its role or group.
notify(C, TaskId, Case, Kind, Msg) ->
    {ok, _} = ana_db:query(C,
        "INSERT INTO bpm.notification (username, task_id, case_id, kind, message) "
        "SELECT u.username, $1, $2, $3, $4 FROM ana_system.app_user u, bpm.task t "
        "WHERE t.id = $1 AND u.active AND u.kind = 'human' AND ( "
        "  (t.assignee IS NOT NULL AND u.username = t.assignee) OR "
        "  (t.assignee IS NULL AND t.role IS NOT NULL AND u.role = t.role) OR "
        "  (t.assignee IS NULL AND t.group_name IS NOT NULL AND EXISTS (SELECT 1 FROM ana_system.user_group g "
        "     WHERE g.username = u.username AND g.group_name = t.group_name))) LIMIT 50",
        [TaskId, Case, Kind, Msg]),
    ok.

%% ---------------------------------------------------------------- 2. automatic work

claim(N) ->
    case ana_db:rows(
            "UPDATE bpm.task x SET status = 'running', lease_until = now() + " ?LEASE ", "
            "  started_at = COALESCE(x.started_at, now()), attempts = x.attempts + 1 "
            "FROM (SELECT id FROM bpm.task WHERE kind IN ('auto', 'send', 'timer', 'subprocess') AND "
            "      ((status = 'ready' AND next_at <= now()) OR (status = 'running' AND lease_until < now())) "
            "      ORDER BY next_at NULLS FIRST LIMIT $1 FOR UPDATE SKIP LOCKED) c "
            "WHERE x.id = c.id RETURNING x.id, x.case_id, x.node, x.kind, x.program, x.params, x.attempts", [N]) of
        {ok, Rows} -> Rows;
        {error, E} -> logger:warning("bpm: claim failed: ~0p", [E]), []
    end.

run_task(T = #{<<"id">> := TId}) ->
    try do_run(T)
    catch C:R:St ->
        logger:error("bpm task ~p crashed: ~0p:~0p ~0p", [TId, C, R, St]),
        fail_task(TId, #{<<"code">> => <<"INTERNAL">>, <<"message">> => <<"falha interna do motor (veja o log)"/utf8>>}, null)
    end.

do_run(#{<<"id">> := TId, <<"kind">> := <<"timer">>}) ->
    done_task(TId, null, <<"auto">>, null, null);
do_run(#{<<"id">> := TId, <<"kind">> := <<"subprocess">>, <<"case_id">> := Parent, <<"program">> := Proc}) ->
    case ana_db:transaction(fun(C) -> start_child(C, TId, Parent, Proc) end) of
        {ok, _} -> ok;
        {error, #{message := M}} -> fail_task(TId, #{<<"code">> => <<"SUBPROCESS">>, <<"message">> => M}, null);
        {error, E} -> fail_task(TId, #{<<"code">> => <<"SUBPROCESS">>, <<"message">> => iolist_to_binary(io_lib:format("~0p", [E]))}, null)
    end;
do_run(#{<<"id">> := TId, <<"case_id">> := Case, <<"node">> := Node, <<"program">> := Program, <<"params">> := Tpl,
         <<"attempts">> := Attempts}) ->
    {ok, Ctx} = ana_db:one(
        "SELECT c.data, c.doc_key, d.facts_sql, v.model FROM bpm.case c JOIN bpm.document d ON d.entity = c.doc_entity "
        "JOIN bpm.version v ON v.process_code = c.process_code AND v.version = c.version WHERE c.id = $1", [Case]),
    #{<<"data">> := Data, <<"model">> := Model, <<"doc_key">> := Key} = Ctx,
    Facts = case Key of
        null -> #{};
        _ -> case ana_db:rows(maps:get(<<"facts_sql">>, Ctx), [Key]) of {ok, [F | _]} -> F#{<<"key">> => Key}; _ -> #{} end
    end,
    Eval = maps:merge(Facts, maps:remove(<<"doc">>, Data)),
    User = ana_flows:user(maps:get(<<"run_as">>, Model, <<"system">>)),
    Max = case ana_bpm_model:node(Model, Node) of
        #{<<"props">> := #{<<"max_attempts">> := M}} when is_integer(M) -> M;
        _ -> 5
    end,
    case Program of
        null -> done_task(TId, null, <<"auto">>, null, null);
        _ ->
            case ana_execution:run(Program, ana_flows:render(Tpl, Eval), User, #{origin => <<"internal">>}) of
                {ok, #{id := Exec, result := Res}} -> done_task(TId, ana_flows:small(Res), <<"auto">>, Exec, null);
                {error, E} ->
                    Code = ana_flows:code(E),
                    Exec = maps:get(<<"execution_id">>, E, null),
                    case lists:member(Code, ana_checks:technical_codes()) andalso Attempts < Max of
                        true -> retry_task(TId, Attempts, E, Exec);
                        false ->
                            case ana_bpm_model:next(Model, Node, Eval, <<"error">>) of
                                {ok, [_ | _]} -> done_task(TId, null, <<"auto">>, Exec, {<<"error">>, clean(E)});
                                _ -> fail_task(TId, E, Exec)
                            end
                    end
            end
    end.

start_child(C, TId, Parent, Proc) ->
    {ok, Rows} = ana_db:rows(C,
        "SELECT v.version, v.compiled, p.name, c.doc_entity, c.doc_key, c.started_by FROM bpm.version v "
        "JOIN bpm.process p ON p.code = v.process_code, bpm.case c WHERE v.process_code = $1 AND v.status = 'published' "
        "AND c.id = $2", [Proc, Parent]),
    case Rows of
        [] -> {error, #{message => <<"subprocesso sem versão publicada: "/utf8, (text(Proc))/binary>>}};
        [#{<<"version">> := V, <<"compiled">> := Comp, <<"name">> := Name, <<"doc_entity">> := Ent, <<"doc_key">> := Key,
           <<"started_by">> := By}] ->
            Start = maps:get(<<"start">>, Comp),
            {ok, [#{<<"id">> := Child}]} = ana_db:rows(C,
                "INSERT INTO bpm.case (process_code, version, doc_entity, doc_key, title, parent_task, started_by) "
                "VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id", [Proc, V, Ent, Key, Name, TId, By]),
            {ok, [#{<<"id">> := Tok}]} = ana_db:rows(C, "INSERT INTO bpm.token (case_id, node) VALUES ($1, $2) RETURNING id",
                                                     [Child, Start]),
            {ok, _} = ana_db:query(C, <<"INSERT INTO bpm.task (case_id, token_id, node, kind, name, status, how, finished_at) "
                                        "VALUES ($1, $2, $3, 'rule', 'Início', 'done', 'auto', now())"/utf8>>, [Child, Tok, Start]),
            event(C, Child, Start, <<"start">>, By, #{<<"parent_case">> => Parent}),
            {ok, _} = ana_db:query(C, "UPDATE bpm.task SET status = 'waiting', child_case = $2, lease_until = NULL WHERE id = $1",
                                   [TId, Child]),
            {ok, Child}
    end.

text(B) when is_binary(B) -> B;
text(X) -> iolist_to_binary(io_lib:format("~p", [X])).

done_task(TId, Result, How, Exec, Outcome) ->
    {O, Err} = case Outcome of {<<"error">>, E} -> {<<"error">>, E}; _ -> {null, null} end,
    {ok, _} = ana_db:exec("UPDATE bpm.task SET status = 'done', result = $2, how = $3, execution_id = $4::text::uuid, "
                          "  outcome = $5, error = $6, lease_until = NULL, finished_at = now() WHERE id = $1",
                          [TId, Result, How, Exec, O, Err]),
    ok.

retry_task(TId, Attempts, E, Exec) ->
    Delay = min(3600, 30 * (1 bsl min(Attempts - 1, 7))),
    {ok, _} = ana_db:exec("UPDATE bpm.task SET status = 'ready', next_at = now() + make_interval(secs => $2), error = $3, "
                          "  execution_id = $4::text::uuid, lease_until = NULL WHERE id = $1", [TId, Delay, clean(E), Exec]),
    ok.

fail_task(TId, E, Exec) ->
    {ok, _} = ana_db:exec("UPDATE bpm.task SET status = 'failed', error = $2, execution_id = COALESCE($3::text::uuid, execution_id), "
                          "  lease_until = NULL, finished_at = now() WHERE id = $1", [TId, clean(E), Exec]),
    ok.

clean(E) -> maps:with([<<"code">>, <<"message">>, <<"data">>, code, message], E).

%% ---------------------------------------------------------------- 3. sweep

sweep() ->
    _ = safe(fun ana_flows:sweep/0),
    _ = safe(fun facts_sweep/0),
    _ = safe(fun deadlines/0),
    _ = safe(fun children/0),
    _ = safe(fun cancelled_documents/0),
    ok.

safe(F) ->
    try F() catch C:R:St -> logger:warning("bpm sweep: ~0p:~0p ~0p", [C, R, St]) end.

%% Waiting tasks completed by a fact of the ERP (the document moved, by the case or by anyone).
facts_sweep() ->
    {ok, Rows} = ana_db:rows("SELECT t.id, t.fact, c.doc_key FROM bpm.task t JOIN bpm.case c ON c.id = t.case_id "
                             "WHERE t.status = 'waiting' AND t.fact IS NOT NULL AND c.doc_key IS NOT NULL ORDER BY t.id LIMIT 2000", []),
    lists:foreach(fun(#{<<"id">> := T, <<"fact">> := F, <<"doc_key">> := K}) ->
        {ok, _} = ana_db:transaction(fun(C) -> complete_if_fact(C, T, F, K), {ok, done} end)
    end, Rows).

%% RF-039-13: warning before the deadline, escalation after it (in working hours).
deadlines() ->
    {ok, Warn} = ana_db:rows("UPDATE bpm.task SET warned = true WHERE status = 'waiting' AND NOT warned AND warn_at < now() "
                             "RETURNING id, case_id, name", []),
    _ = [ana_db:transaction(fun(C) ->
             notify(C, T, Case, <<"warn">>, <<"Tarefa perto do prazo: "/utf8, N/binary>>), {ok, done} end)
         || #{<<"id">> := T, <<"case_id">> := Case, <<"name">> := N} <- Warn],
    {ok, Late} = ana_db:rows("UPDATE bpm.task SET escalated = true WHERE status = 'waiting' AND NOT escalated AND due_at < now() "
                             "AND kind IN ('human', 'approval') RETURNING id, case_id, node, name, escalate", []),
    lists:foreach(fun(#{<<"id">> := T, <<"case_id">> := Case, <<"node">> := Node, <<"name">> := N, <<"escalate">> := Esc}) ->
        {ok, _} = ana_db:transaction(fun(C) ->
            event(C, Case, Node, <<"escalate">>, null, Esc),
            To = case Esc of #{<<"to">> := U} when is_binary(U), U =/= <<>> -> U; _ -> null end,
            _ = case Esc of
                #{<<"mode">> := <<"path">>} ->
                    {ok, _} = ana_db:query(C, "UPDATE bpm.task SET status = 'done', outcome = 'timeout', how = 'timeout', "
                                              "finished_at = now() WHERE id = $1", [T]);
                #{<<"mode">> := <<"reassign">>} when To =/= null ->
                    {ok, _} = ana_db:query(C, "UPDATE bpm.task SET assignee = $2 WHERE id = $1", [T, To]),
                    notify(C, T, Case, <<"escalated">>, <<"Tarefa atrasada passou para você: "/utf8, N/binary>>);
                _ when To =/= null ->
                    {ok, _} = ana_db:query(C, "INSERT INTO bpm.notification (username, task_id, case_id, kind, message) "
                                              "VALUES ($1, $2, $3, 'escalated', $4)",
                                           [To, T, Case, <<"Tarefa atrasada: "/utf8, N/binary>>]);
                _ -> notify(C, T, Case, <<"escalated">>, <<"Tarefa atrasada: "/utf8, N/binary>>)
            end,
            {ok, done}
        end)
    end, Late).

children() ->
    {ok, _} = ana_db:exec(
        "UPDATE bpm.task t SET status = CASE WHEN c.status = 'done' THEN 'done' ELSE 'failed' END, how = 'auto', "
        "  error = CASE WHEN c.status <> 'done' THEN jsonb_build_object('code', 'SUBPROCESS', 'message', "
        "    'subprocesso ' || c.status || COALESCE(': ' || c.reason, '')) END, finished_at = now() "
        "FROM bpm.case c WHERE c.id = t.child_case AND t.status = 'waiting' AND t.kind = 'subprocess' "
        "  AND c.status IN ('done', 'cancelled')", []),
    ok.

cancelled_documents() ->
    {ok, Rows} = ana_db:rows("SELECT c.id, c.doc_key, d.cancel_sql FROM bpm.case c JOIN bpm.document d ON d.entity = c.doc_entity "
                             "WHERE c.status IN ('running', 'waiting', 'failed') AND d.cancel_sql IS NOT NULL AND c.doc_key IS NOT NULL "
                             "LIMIT 2000", []),
    lists:foreach(fun(#{<<"id">> := Id, <<"doc_key">> := K, <<"cancel_sql">> := Sql}) ->
        case ana_flows:check(Sql, K) of
            true -> cancel_case(Id, <<"documento cancelado"/utf8>>);
            false -> ok
        end
    end, Rows).

cancel_case(Id, Reason) ->
    {ok, _} = ana_db:transaction(fun(C) ->
        {ok, _} = ana_db:query(C, "UPDATE bpm.task SET status = 'cancelled', advanced = true, finished_at = now() "
                                  "WHERE case_id = $1 AND status IN ('ready', 'running', 'waiting', 'failed')", [Id]),
        {ok, _} = ana_db:query(C, "UPDATE bpm.token SET status = 'cancelled' WHERE case_id = $1 AND status IN ('active', 'joining')", [Id]),
        {ok, _} = ana_db:query(C, "UPDATE bpm.case SET status = 'cancelled', reason = $2, finished_at = now(), updated_at = now() "
                                  "WHERE id = $1", [Id, Reason]),
        event(C, Id, null, <<"cancel">>, null, #{<<"reason">> => Reason}),
        {ok, done}
    end),
    ok.
