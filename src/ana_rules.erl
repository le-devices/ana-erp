%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Rules "when… then…" (spec 051, D2, RF-051-02, RNF-051-01): a document created or changing status, a time, a metric
%% passing a limit or a message received; conditions of the condition builder on the document's facts; one action of
%% a closed list, run as the rule's owner (P14) like any execution — with rehearsal, trail and limits.
%%
%% Events of documents are queued by the database itself (automation.pending, only when an active rule watches them)
%% and woken by NOTIFY "ana_wake/rules" after the COMMIT (spec 062: events, not polling); a safety timer drains what a
%% lost notification left behind and runs the time and metric triggers (leader only). The work runs in a monitored
%% process: a slow action never blocks the server.
%%
%% Never in a loop: each action carries the chain of rules that led to it (SET LOCAL ana.rule_chain); a rule that comes
%% back in its own chain, or fires more than its limit in its window, is blocked and turned off, with a notice to its owner.
-module(ana_rules).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([list/0, get/1, save/2, delete/2, activate/3, rehearse/3, catalog/0]).

-define(TICK_MS, 60000).
-define(BATCH, 200).
-define(FIRES_SHOWN, 50).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ok = ana_events:subscribe(<<"rules">>),
    erlang:send_after(5000, self(), tick),
    {ok, #{worker => undefined, again => false, metrics => #{}, minute => undefined}}.

handle_call(_, _From, S) -> {reply, {error, unknown}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info({ana_event, <<"rules">>, _}, S) -> {noreply, work(S#{again := true}, [])};
handle_info(tick, S) ->
    erlang:send_after(?TICK_MS, self(), tick),
    {Timed, S2} = timed(S),
    {noreply, work(S2#{again := true}, Timed)};
handle_info({'DOWN', Ref, process, _, _}, S = #{worker := Ref, again := Again}) ->
    S2 = S#{worker := undefined},
    {noreply, case Again of true -> work(S2#{again := false}, []); false -> S2 end};
handle_info(_, S) -> {noreply, S}.

%% One worker at a time; what arrives meanwhile runs right after it.
work(S = #{worker := undefined}, Timed) ->
    case leader() of
        false -> S#{again := false};
        true ->
            {_, Ref} = spawn_monitor(fun() -> drain(), [safe(F) || F <- Timed], resolve_tasks() end),
            S#{worker := Ref, again := false}
    end;
work(S, []) -> S;
work(S, Timed) ->
    _ = spawn(fun() -> [safe(F) || F <- Timed] end),
    S.

safe(F) -> try F() catch C:R:St -> logger:warning("rules: ~0p:~0p ~0p", [C, R, St]) end.

leader() ->
    case catch ana_scheduler:status() of
        #{leader := true} -> true;
        _ -> false
    end.

%% ---------------------------------------------------------------- time and metric triggers

%% Once a minute: the schedule rules due in this minute, and the metric rules whose limit has just been passed
%% (edge, not level: a metric above its limit for an hour fires once, when it passes it).
timed(S = #{minute := Last, metrics := Prev}) ->
    Minute = minute_now(),
    Sched = case Minute =:= Last of
        true -> [];
        false -> [fun() -> schedules(Minute) end]
    end,
    Values = metrics_now(),
    {Now, Fns} = case active_rules(<<"metric">>) of
        [] -> {#{}, []};
        Rules ->
            lists:foldl(fun(R = #{<<"id">> := Id, <<"metric">> := M, <<"metric_op">> := Op, <<"metric_value">> := V}, {Acc, F}) ->
                Holds = case maps:find(M, Values) of
                    {ok, X} when is_number(X) -> cmp(Op, X, num(V));
                    _ -> false
                end,
                F2 = case Holds andalso not maps:get(Id, Prev, false) of
                    true -> [fun() -> fire(R, #{kind => <<"metric">>, facts => #{<<"metric">> => M, <<"value">> => maps:get(M, Values)},
                                                chain => []}) end | F];
                    false -> F
                end,
                {Acc#{Id => Holds}, F2}
            end, {#{}, []}, Rules)
    end,
    {Sched ++ Fns, S#{minute := Minute, metrics := Now}}.

minute_now() ->
    {D, {H, Mi, _}} = local_now(),
    {D, {H, Mi, 0}}.

local_now() ->
    case ana_db:one("SELECT to_char(now() AT TIME ZONE $1, 'YYYY-MM-DD HH24:MI:SS') AS t", [ana_config:timezone()]) of
        {ok, #{<<"t">> := T}} ->
            [Y, Mo, D, H, Mi, Se] = [binary_to_integer(X) || X <- binary:split(T, [<<"-">>, <<" ">>, <<":">>], [global])],
            {{Y, Mo, D}, {H, Mi, Se}};
        _ -> calendar:local_time()
    end.

schedules(Minute) ->
    Before = calendar:gregorian_seconds_to_datetime(calendar:datetime_to_gregorian_seconds(Minute) - 60),
    lists:foreach(fun(R = #{<<"cron">> := Cron}) ->
        case ana_cron:parse(Cron) of
            {ok, C} ->
                case catch ana_cron:next(C, Before) of
                    Minute -> fire(R, #{kind => <<"schedule">>, facts => #{<<"at">> => fmt(Minute)}, chain => []});
                    _ -> ok
                end;
            _ -> ok
        end
    end, active_rules(<<"schedule">>)).

metrics_now() ->
    try ana_health:metrics() catch _:_ -> #{} end.

cmp(<<">">>, A, B) -> A > B;
cmp(<<">=">>, A, B) -> A >= B;
cmp(<<"<">>, A, B) -> A < B;
cmp(<<"<=">>, A, B) -> A =< B;
cmp(_, _, _) -> false.

num(V) when is_number(V) -> V;
num(V) when is_binary(V) ->
    try binary_to_float(V) catch _:_ -> try binary_to_integer(V) catch _:_ -> 0 end end;
num(_) -> 0.

fmt({{Y, Mo, D}, {H, Mi, _}}) ->
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B", [Y, Mo, D, H, Mi])).

active_rules(Kind) ->
    case ana_db:rows("SELECT * FROM automation.rule WHERE active AND trigger_kind = $1 ORDER BY id", [Kind]) of
        {ok, Rows} -> Rows;
        _ -> []
    end.

%% ---------------------------------------------------------------- events of documents and messages

drain() ->
    case ana_db:rows("DELETE FROM automation.pending WHERE id IN (SELECT id FROM automation.pending ORDER BY id "
                     "LIMIT " ++ integer_to_list(?BATCH) ++ " FOR UPDATE SKIP LOCKED) RETURNING *", []) of
        {ok, []} -> ok;
        {ok, Events} ->
            lists:foreach(fun(E) -> safe(fun() -> event(E) end) end, lists:sort(fun(A, B) -> id(A) =< id(B) end, Events)),
            drain();
        {error, E} -> logger:warning("rules: pending not read: ~0p", [E])
    end.

id(#{<<"id">> := I}) -> I.

event(#{<<"kind">> := <<"message">>, <<"doc_key">> := Key, <<"connector">> := Conn, <<"chain">> := Chain}) ->
    {ok, Rules} = ana_db:rows("SELECT * FROM automation.rule WHERE active AND trigger_kind = 'message' AND connector = $1 "
                              "ORDER BY id", [Conn]),
    Facts = case ana_db:one("SELECT event_id, payload FROM integration.inbox WHERE id = $1::bigint", [Key]) of
        {ok, #{<<"payload">> := P, <<"event_id">> := Ev}} when is_map(P) -> P#{<<"event_id">> => Ev, <<"connector">> => Conn};
        _ -> #{<<"connector">> => Conn}
    end,
    [fire(R, #{kind => <<"message">>, entity => null, key => Key, facts => Facts, chain => chain(Chain)}) || R <- Rules],
    ok;
event(#{<<"kind">> := Kind, <<"entity">> := Ent, <<"doc_key">> := Key, <<"status_to">> := To, <<"chain">> := Chain}) ->
    {ok, Rules} = ana_db:rows("SELECT * FROM automation.rule WHERE active AND trigger_kind = $1 AND entity = $2 "
                              "AND ($1 = 'created' OR status_to IS NULL OR status_to = $3) ORDER BY id", [Kind, Ent, To]),
    case Rules of
        [] -> ok;
        _ ->
            Facts = facts(Ent, Key),
            [fire(R, #{kind => Kind, entity => Ent, key => Key, facts => Facts, chain => chain(Chain)}) || R <- Rules],
            ok
    end.

chain(L) when is_list(L) -> [I || I <- L, is_integer(I)];
chain(_) -> [].

facts(Ent, Key) ->
    case ana_db:one("SELECT facts_sql FROM bpm.document WHERE entity = $1", [Ent]) of
        {ok, #{<<"facts_sql">> := Sql}} ->
            case ana_db:rows(Sql, [Key]) of
                {ok, [Row | _]} -> Row#{<<"key">> => Key};
                _ -> #{<<"key">> => Key}
            end;
        _ -> #{<<"key">> => Key}
    end.

%% ---------------------------------------------------------------- firing

fire(R = #{<<"id">> := Id, <<"max_fires">> := Max, <<"window_minutes">> := Win}, Ev = #{chain := Chain}) ->
    Facts = maps:get(facts, Ev, #{}),
    case lists:member(Id, Chain) of
        true ->
            block(R, Ev, <<"a regra disparou a si mesma: a ação dela gerou de novo o evento que a dispara "
                           "(cadeia de regras "/utf8, (chain_text(Chain ++ [Id]))/binary, ")">>);
        false ->
            {ok, #{<<"n">> := N}} = ana_db:one("SELECT count(*)::int AS n FROM automation.fire WHERE rule_id = $1 "
                                               "AND outcome IN ('done', 'failed') AND at > now() - make_interval(mins => $2)",
                                               [Id, Win]),
            case N >= Max of
                true ->
                    block(R, Ev, iolist_to_binary(io_lib:format("passou do limite de ~b disparos em ~b minuto(s)", [Max, Win])));
                false ->
                    case ana_flows:condition(maps:get(<<"conditions">>, R), Facts) of
                        false -> ok;
                        true -> act_and_record(R, Ev, Facts)
                    end
            end
    end.

act_and_record(R = #{<<"id">> := Id}, Ev = #{chain := Chain}, Facts) ->
    {Outcome, Detail, Exec} = case act(R, Ev, Facts, false) of
        {ok, #{id := X, result := Res}} -> {<<"done">>, #{<<"result">> => ana_flows:small(Res)}, X};
        {error, E} -> {<<"failed">>, #{<<"error">> => maps:with([<<"code">>, <<"message">>], E)},
                       maps:get(<<"execution_id">>, E, null)}
    end,
    record(Id, Ev, Outcome, Detail, Exec, Chain ++ [Id], <<"system">>),
    {ok, _} = ana_db:exec("UPDATE automation.rule SET last_fired_at = now() WHERE id = $1", [Id]),
    case Outcome of
        <<"failed">> -> notify_owner(R, <<"failed">>, <<"A regra \""/utf8, (maps:get(<<"name">>, R))/binary,
                                                       "\" falhou: "/utf8, (err_text(Detail))/binary>>);
        _ -> ok
    end,
    ok.

err_text(#{<<"error">> := #{<<"message">> := M}}) when is_binary(M) -> M;
err_text(_) -> <<"veja o histórico da regra"/utf8>>.

%% The action runs as the rule's owner, like any execution: a routine of the catalog, or automation.act for the
%% actions of the closed list (task, notice, e-mail, connector) — so a rehearsal holds and lists every one of them.
act(R = #{<<"id">> := Id, <<"owner">> := Owner, <<"action">> := A}, Ev, Facts, Rehearse) ->
    Chain = maps:get(chain, Ev, []) ++ [Id],
    {Program, Params} = case A of
        #{<<"kind">> := <<"run">>, <<"program">> := P} ->
            {P, ana_flows:render(maps:get(<<"params">>, A, #{}), Facts)};
        _ ->
            {<<"automation.act">>, #{<<"action">> => ana_flows:render(A, Facts), <<"facts">> => Facts,
                                     <<"rule">> => Id, <<"rule_name">> => maps:get(<<"name">>, R),
                                     <<"entity">> => maps:get(entity, Ev, null), <<"key">> => maps:get(key, Ev, null)}}
    end,
    Opts0 = #{origin => <<"internal">>, rule_chain => Chain},
    Opts = case Rehearse of true -> Opts0#{rehearse => true}; false -> Opts0 end,
    ana_execution:run(Program, Params, ana_flows:user(Owner), Opts).

record(Id, Ev, Outcome, Detail, Exec, Chain, By) ->
    {ok, _} = ana_db:exec("INSERT INTO automation.fire (rule_id, entity, doc_key, outcome, detail, execution_id, chain, by) "
                          "VALUES ($1, $2, $3, $4, $5, $6::text::uuid, $7, $8)",
                          [Id, maps:get(entity, Ev, null), maps:get(key, Ev, null), Outcome, Detail, Exec, Chain, By]),
    ok.

%% RNF-051-01, CA-051-03: blocked and turned off, with a notice — never a loop, never silence.
block(R = #{<<"id">> := Id, <<"name">> := Name}, Ev, Reason) ->
    {ok, N} = ana_db:exec("UPDATE automation.rule SET active = false, blocked_reason = $2, blocked_at = now() "
                          "WHERE id = $1 AND active", [Id, Reason]),
    case N of
        0 -> ok;                                                     % already blocked by another event of the batch
        _ ->
            record(Id, Ev, <<"blocked">>, #{<<"reason">> => Reason}, null, maps:get(chain, Ev, []), <<"system">>),
            Msg = <<"Regra \""/utf8, Name/binary, "\" bloqueada e desligada: "/utf8, Reason/binary>>,
            _ = ana_db:exec("INSERT INTO ana_system.notice (kind, severity, message, link) VALUES ('automation_rule', 'serious', $1, $2)",
                            [Msg, <<"#/admin/automations/rules/", (integer_to_binary(Id))/binary>>]),
            notify_owner(R, <<"failed">>, Msg)
    end.

notify_owner(#{<<"owner">> := Owner}, Kind, Msg) ->
    _ = ana_db:exec("INSERT INTO bpm.notification (username, kind, message) VALUES ($1, $2, $3)",
                    [Owner, Kind, binary:part(Msg, 0, min(byte_size(Msg), 1900))]),
    ok.

chain_text(L) -> iolist_to_binary(lists:join(<<" → "/utf8>>, [integer_to_binary(I) || I <- L])).

%% ---------------------------------------------------------------- ERP tasks that resolve by themselves (RF-051-05)

%% An exception task says when it is over (resolve): a failed step of an esteira that left the failure — retried by
%% someone, done outside, skipped — closes its task by itself.
resolve_tasks() ->
    case ana_db:rows("SELECT t.id, t.resolve FROM bpm.task t JOIN bpm.case c ON c.id = t.case_id "
                     "WHERE c.process_code = 'erp.tarefa' AND t.status = 'waiting' AND t.resolve IS NOT NULL LIMIT 500", []) of
        {ok, Rows} ->
            lists:foreach(fun(#{<<"id">> := T, <<"resolve">> := #{<<"flow_instance">> := I, <<"seq">> := Seq}}) ->
                                  case ana_db:one("SELECT status FROM flow.instance_step WHERE instance_id = $1 AND seq = $2",
                                                  [I, Seq]) of
                                      {ok, #{<<"status">> := St}} when St =/= <<"failed">> -> close_task(T, St);
                                      {ok, undefined} -> close_task(T, <<"gone">>);
                                      _ -> ok
                                  end;
                             (_) -> ok
                          end, Rows);
        _ -> ok
    end.

close_task(T, Why) ->
    {ok, _} = ana_db:exec("UPDATE bpm.task SET status = 'done', how = 'auto', outcome = 'resolved', "
                          "result = jsonb_build_object('resolved', $2::text), finished_at = now() "
                          "WHERE id = $1 AND status = 'waiting'", [T, Why]),
    ok.

%% ---------------------------------------------------------------- the rules screen (API)

entity_table(<<"sales_order">>) -> {<<"sales.sales_order">>, <<"number">>};
entity_table(<<"purchase_request">>) -> {<<"supply.purchase_request">>, <<"number">>};
entity_table(<<"service_order">>) -> {<<"field.service_order">>, <<"number">>};
entity_table(<<"work_order">>) -> {<<"production.work_order">>, <<"number">>};
entity_table(<<"project">>) -> {<<"projects.project">>, <<"code">>};
entity_table(_) -> undefined.

-spec list() -> [map()].
list() ->
    {ok, Rows} = ana_db:rows(
        "SELECT r.*, d.label AS entity_label, "
        "  (SELECT count(*) FROM automation.fire f WHERE f.rule_id = r.id AND f.outcome = 'done') AS fired, "
        "  (SELECT count(*) FROM automation.fire f WHERE f.rule_id = r.id AND f.outcome = 'failed') AS failed, "
        "  (SELECT jsonb_build_object('at', f.at, 'outcome', f.outcome, 'detail', f.detail) FROM automation.fire f "
        "    WHERE f.rule_id = r.id AND f.outcome <> 'rehearsal' ORDER BY f.id DESC LIMIT 1) AS last "
        "FROM automation.rule r LEFT JOIN bpm.document d ON d.entity = r.entity ORDER BY r.name", []),
    Rows.

-spec get(integer()) -> {ok, map()} | {error, not_found}.
get(Id) ->
    case ana_db:one("SELECT r.*, d.label AS entity_label FROM automation.rule r LEFT JOIN bpm.document d ON d.entity = r.entity "
                    "WHERE r.id = $1", [Id]) of
        {ok, R = #{}} ->
            {ok, Fires} = ana_db:rows("SELECT id, at, entity, doc_key, outcome, detail, execution_id, chain, by "
                                      "FROM automation.fire WHERE rule_id = $1 ORDER BY id DESC LIMIT " ++
                                      integer_to_list(?FIRES_SHOWN), [Id]),
            {ok, R#{<<"fires">> => Fires}};
        _ -> {error, not_found}
    end.

%% What the screen offers: documents (with the statuses seen), metrics, connectors, groups, users and routines.
-spec catalog() -> map().
catalog() ->
    {ok, Docs} = ana_db:rows("SELECT entity, label FROM bpm.document WHERE entity <> 'none' ORDER BY label", []),
    Docs2 = [D#{<<"statuses">> => statuses(E), <<"fields">> => fields(E)} || D = #{<<"entity">> := E} <- Docs],
    {ok, Conns} = ana_db:rows("SELECT name FROM integration.connector ORDER BY name", []),
    {ok, Groups} = ana_db:rows("SELECT name FROM ana_system.access_group ORDER BY name", []),
    {ok, Users} = ana_db:rows("SELECT username FROM ana_system.app_user WHERE active AND kind = 'human' ORDER BY username", []),
    #{<<"documents">> => Docs2, <<"metrics">> => ana_health:metric_names(),
      <<"connectors">> => [N || #{<<"name">> := N} <- Conns], <<"groups">> => [N || #{<<"name">> := N} <- Groups],
      <<"users">> => [N || #{<<"username">> := N} <- Users]}.

%% The facts of the latest document of the kind: the fields the condition builder offers, with their type.
fields(E) ->
    case latest_key(E) of
        null -> [];
        Key -> [#{<<"name">> => K, <<"type">> => case V of _ when is_number(V) -> <<"number">>;
                                                          _ when is_boolean(V) -> <<"bool">>;
                                                          _ -> <<"text">> end}
                || {K, V} <- lists:sort(maps:to_list(facts(E, Key))), K =/= <<"key">>]
    end.

latest_key(E) ->
    case entity_table(E) of
        {T, Col} ->
            case ana_db:one(<<"SELECT ", Col/binary, "::text AS k FROM ", T/binary, " ORDER BY ", Col/binary, " DESC LIMIT 1">>, []) of
                {ok, #{<<"k">> := K}} -> K;
                _ -> null
            end;
        undefined -> null
    end.

statuses(E) ->
    case entity_table(E) of
        {T, _} ->
            case ana_db:rows(<<"SELECT DISTINCT status FROM ", T/binary, " WHERE status IS NOT NULL ORDER BY 1 LIMIT 30">>, []) of
                {ok, Rows} -> [S || #{<<"status">> := S} <- Rows];
                _ -> []
            end;
        undefined -> []
    end.

%% Saves a rule (new or changed). A change bumps the version and turns the rule off: it is rehearsed again before it
%% is turned on (CA-051-01). Returns {ok, Id} | {error, Code, Message}.
-spec save(map(), binary()) -> {ok, integer()} | {error, binary(), binary()}.
save(In, Who) ->
    case validate(In) of
        {error, _, _} = E -> E;
        {ok, V} ->
            Cols = [<<"name">>, <<"description">>, <<"owner">>, <<"trigger_kind">>, <<"entity">>, <<"status_to">>,
                    <<"cron">>, <<"metric">>, <<"metric_op">>, <<"metric_value">>, <<"connector">>, <<"conditions">>,
                    <<"action">>, <<"max_fires">>, <<"window_minutes">>],
            Vals = [maps:get(K, V, null) || K <- Cols],
            Res = case maps:get(<<"id">>, In, null) of
                null ->
                    ana_db:one("INSERT INTO automation.rule (name, description, owner, trigger_kind, entity, status_to, cron, "
                               "  metric, metric_op, metric_value, connector, conditions, action, max_fires, window_minutes, "
                               "  created_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::text::numeric, $11, $12, $13, "
                               "  $14, $15, $16) RETURNING id", Vals ++ [Who]);
                Id when is_integer(Id) ->
                    ana_db:one("UPDATE automation.rule SET name = $2, description = $3, owner = $4, trigger_kind = $5, "
                               "  entity = $6, status_to = $7, cron = $8, metric = $9, metric_op = $10, "
                               "  metric_value = $11::text::numeric, connector = $12, conditions = $13, action = $14, "
                               "  max_fires = $15, window_minutes = $16, version = version + 1, active = false, "
                               "  blocked_reason = NULL, blocked_at = NULL, updated_by = $17, updated_at = now() "
                               "WHERE id = $1 RETURNING id", [Id | Vals] ++ [Who]);
                _ -> {error, bad_id}
            end,
            case Res of
                {ok, #{<<"id">> := New}} -> {ok, New};
                {ok, undefined} -> {error, <<"NOT_FOUND">>, <<"regra não encontrada"/utf8>>};
                {error, #{sqlstate := <<"23505">>}} -> {error, <<"DUPLICATE">>, <<"já existe uma regra com este nome"/utf8>>};
                {error, E} -> {error, <<"INVALID_PARAMETER">>, iolist_to_binary(io_lib:format("~0p", [E]))}
            end
    end.

%% Never code: the trigger, the conditions and the action are checked against the closed lists.
-spec validate(map()) -> {ok, map()} | {error, binary(), binary()}.
validate(In) ->
    try
        Name = trim(req(<<"name">>, In, <<"diga o nome da regra"/utf8>>)),
        Owner = req(<<"owner">>, In, <<"toda regra tem dono (P14)"/utf8>>),
        human(Owner) orelse throw(<<"o dono precisa ser uma pessoa ativa"/utf8>>),
        Kind = req(<<"trigger_kind">>, In, <<"diga quando a regra dispara"/utf8>>),
        Trigger = trigger(Kind, In),
        Conds = maps:get(<<"conditions">>, In, []),
        (is_list(Conds) orelse is_map(Conds)) orelse throw(<<"condições inválidas"/utf8>>),
        Action = action(maps:get(<<"action">>, In, null), Owner),
        Max = int(maps:get(<<"max_fires">>, In, 20), 1, 10000, <<"limite de disparos entre 1 e 10.000"/utf8>>),
        Win = int(maps:get(<<"window_minutes">>, In, 60), 1, 10080, <<"janela entre 1 minuto e 7 dias"/utf8>>),
        {ok, maps:merge(Trigger, #{<<"name">> => Name, <<"description">> => maps:get(<<"description">>, In, <<>>),
                                   <<"owner">> => Owner, <<"trigger_kind">> => Kind, <<"conditions">> => Conds,
                                   <<"action">> => Action, <<"max_fires">> => Max, <<"window_minutes">> => Win})}
    catch throw:Msg when is_binary(Msg) -> {error, <<"INVALID_PARAMETER">>, Msg}
    end.

trigger(K, In) when K =:= <<"created">>; K =:= <<"status">> ->
    E = req(<<"entity">>, In, <<"diga qual documento"/utf8>>),
    entity_table(E) =/= undefined orelse throw(<<"documento desconhecido: "/utf8, E/binary>>),
    To = case {K, maps:get(<<"status_to">>, In, null)} of
        {<<"status">>, S} when is_binary(S), S =/= <<>> -> S;
        _ -> null
    end,
    #{<<"entity">> => E, <<"status_to">> => To};
trigger(<<"schedule">>, In) ->
    Cron = req(<<"cron">>, In, <<"diga o horário (cron)"/utf8>>),
    case ana_cron:parse(Cron) of
        {ok, _} -> #{<<"cron">> => Cron};
        _ -> throw(<<"horário inválido (cron com 5 campos: minuto hora dia mês dia-da-semana)"/utf8>>)
    end;
trigger(<<"metric">>, In) ->
    M = req(<<"metric">>, In, <<"diga a métrica"/utf8>>),
    lists:member(M, ana_health:metric_names()) orelse throw(<<"métrica desconhecida: "/utf8, M/binary>>),
    Op = req(<<"metric_op">>, In, <<"diga a comparação"/utf8>>),
    lists:member(Op, [<<">">>, <<">=">>, <<"<">>, <<"<=">>]) orelse throw(<<"comparação inválida"/utf8>>),
    V = maps:get(<<"metric_value">>, In, null),
    is_number(V) orelse throw(<<"diga o limite (número)"/utf8>>),
    #{<<"metric">> => M, <<"metric_op">> => Op, <<"metric_value">> => text(V)};
trigger(<<"message">>, In) ->
    C = req(<<"connector">>, In, <<"diga o conector"/utf8>>),
    case ana_db:one("SELECT name FROM integration.connector WHERE name = $1", [C]) of
        {ok, #{}} -> #{<<"connector">> => C};
        _ -> throw(<<"conector desconhecido: "/utf8, C/binary>>)
    end;
trigger(K, _) -> throw(<<"gatilho desconhecido: "/utf8, K/binary>>).

action(#{<<"kind">> := <<"run">>, <<"program">> := P} = A, Owner) when is_binary(P) ->
    case ana_db:one("SELECT name FROM ana_system.program WHERE name = $1 AND active AND kind = 'program'", [P]) of
        {ok, #{}} -> ok;
        _ -> throw(<<"rotina desconhecida: "/utf8, P/binary>>)
    end,
    can_run(Owner, P) orelse throw(<<"o dono da regra não pode executar "/utf8, P/binary>>),
    Params = maps:get(<<"params">>, A, #{}),
    is_map(Params) orelse throw(<<"parâmetros inválidos"/utf8>>),
    #{<<"kind">> => <<"run">>, <<"program">> => P, <<"params">> => Params};
action(#{<<"kind">> := <<"task">>} = A, _) ->
    Name = trim(req(<<"name">>, A, <<"diga o nome da tarefa"/utf8>>)),
    To = maps:with([<<"assignee">>, <<"group">>, <<"role">>], A),
    lists:any(fun(V) -> is_binary(V) andalso V =/= <<>> end, maps:values(To))
        orelse throw(<<"diga para quem é a tarefa (pessoa, grupo ou papel)"/utf8>>),
    TaskKind = maps:get(<<"task_kind">>, A, <<"human">>),
    lists:member(TaskKind, [<<"human">>, <<"approval">>]) orelse throw(<<"tarefa é de fazer ou de aprovar"/utf8>>),
    maps:merge(maps:with([<<"instructions">>, <<"priority">>, <<"program">>, <<"params">>], A),
               To#{<<"kind">> => <<"task">>, <<"name">> => Name, <<"task_kind">> => TaskKind});
action(#{<<"kind">> := <<"notify">>} = A, _) ->
    Msg = trim(req(<<"message">>, A, <<"diga a mensagem do aviso"/utf8>>)),
    To = maps:with([<<"user">>, <<"group">>], A),
    maps:size(To) > 0 orelse throw(<<"diga quem recebe o aviso (pessoa ou grupo)"/utf8>>),
    To#{<<"kind">> => <<"notify">>, <<"message">> => Msg};
action(#{<<"kind">> := <<"email">>} = A, _) ->
    To = req(<<"to">>, A, <<"diga para quem vai o e-mail"/utf8>>),
    Subject = trim(req(<<"subject">>, A, <<"diga o assunto do e-mail"/utf8>>)),
    maps:merge(maps:with([<<"text">>, <<"connector">>], A), #{<<"kind">> => <<"email">>, <<"to">> => To, <<"subject">> => Subject});
action(#{<<"kind">> := <<"connector">>} = A, _) ->
    C = req(<<"connector">>, A, <<"diga o conector"/utf8>>),
    case ana_db:one("SELECT name FROM integration.connector WHERE name = $1", [C]) of
        {ok, #{}} -> ok;
        _ -> throw(<<"conector desconhecido: "/utf8, C/binary>>)
    end,
    Kind = req(<<"message_kind">>, A, <<"diga o tipo da mensagem"/utf8>>),
    #{<<"kind">> => <<"connector">>, <<"connector">> => C, <<"message_kind">> => Kind,
      <<"payload">> => maps:get(<<"payload">>, A, #{})};
action(_, _) -> throw(<<"diga a ação: executar rotina, criar tarefa, avisar, enviar e-mail ou chamar conector"/utf8>>).

req(K, M, Msg) ->
    case maps:get(K, M, null) of
        V when is_binary(V), V =/= <<>> -> V;
        _ -> throw(Msg)
    end.

trim(B) -> string:trim(B).

int(V, Lo, Hi, _) when is_integer(V), V >= Lo, V =< Hi -> V;
int(_, _, _, Msg) -> throw(Msg).

text(V) when is_integer(V) -> integer_to_binary(V);
text(V) when is_float(V) -> float_to_binary(V, [short]).

human(U) ->
    case ana_db:one("SELECT 1 AS x FROM ana_system.app_user WHERE username = $1 AND active AND kind = 'human'", [U]) of
        {ok, #{}} -> true;
        _ -> false
    end.

can_run(Owner, Program) ->
    User = ana_flows:user(Owner),
    case ana_db:one("SELECT name, min_role, restricted FROM ana_system.program WHERE name = $1", [Program]) of
        {ok, R = #{<<"min_role">> := Min}} -> ana_security:has_role(User, Min) andalso ana_access:allowed(User, R);
        _ -> false
    end.

-spec delete(integer(), binary()) -> ok | {error, not_found}.
delete(Id, _Who) ->
    case ana_db:exec("DELETE FROM automation.rule WHERE id = $1", [Id]) of
        {ok, 1} -> ok;
        _ -> {error, not_found}
    end.

%% Turned on only when rehearsed in the current version (CA-051-01); turning on clears a block.
-spec activate(integer(), boolean(), binary()) -> ok | {error, binary(), binary()}.
activate(Id, On, Who) ->
    case ana_db:exec("UPDATE automation.rule SET active = $2, blocked_reason = CASE WHEN $2 THEN NULL ELSE blocked_reason END, "
                     "  blocked_at = CASE WHEN $2 THEN NULL ELSE blocked_at END, updated_by = $3, updated_at = now() "
                     "WHERE id = $1 AND (NOT $2 OR rehearsed_version = version)", [Id, On, Who]) of
        {ok, 1} -> ok;
        {ok, 0} ->
            case ana_db:one("SELECT id FROM automation.rule WHERE id = $1", [Id]) of
                {ok, #{}} -> {error, <<"NOT_REHEARSED">>, <<"ensaie a regra antes de ligar: ela roda inteira e é desfeita, "
                                                         "para você ver o que faria"/utf8>>};
                _ -> {error, <<"NOT_FOUND">>, <<"regra não encontrada"/utf8>>}
            end;
        {error, E} -> {error, <<"INVALID_STATE">>, iolist_to_binary(io_lib:format("~0p", [E]))}
    end.

%% The rehearsal (CA-051-01): on the document given (or the last one of its kind), the facts, the conditions and the
%% action run whole and undone (spec 056) — what it would create, notify or send is listed, nothing is kept.
-spec rehearse(integer(), binary() | null, binary()) -> {ok, map()} | {error, binary(), binary()}.
rehearse(Id, Key0, Who) ->
    case ana_db:one("SELECT * FROM automation.rule WHERE id = $1", [Id]) of
        {ok, R = #{<<"trigger_kind">> := Kind, <<"entity">> := Ent, <<"version">> := Ver}} ->
            Key = case {Key0, entity_table(Ent)} of
                {K, _} when is_binary(K), K =/= <<>> -> K;
                {_, {_, _}} -> latest_key(Ent);
                _ -> null
            end,
            Facts = case Ent of
                null -> sample_facts(Kind, R);
                _ when Key =:= null -> #{};
                _ -> facts(Ent, Key)
            end,
            Holds = ana_flows:condition(maps:get(<<"conditions">>, R), Facts),
            Ev = #{kind => Kind, entity => Ent, key => Key, facts => Facts, chain => []},
            {Effect, Error} = case Holds of
                false -> {null, null};
                true ->
                    case act(R, Ev, Facts, true) of
                        {ok, Res} -> {maps:get(rehearsal, Res, #{}), null};
                        {error, E} -> {maps:get(<<"rehearsal">>, E, null), maps:with([<<"code">>, <<"message">>], E)}
                    end
            end,
            Out = #{<<"document">> => Key, <<"facts">> => Facts, <<"conditions_hold">> => Holds,
                    <<"effect">> => Effect, <<"error">> => Error},
            record(Id, Ev, <<"rehearsal">>, Out, null, [], Who),
            case Error of
                null -> {ok, _} = ana_db:exec("UPDATE automation.rule SET rehearsed_version = $2 WHERE id = $1 AND version = $2",
                                              [Id, Ver]);
                _ -> ok
            end,
            {ok, Out#{<<"rehearsed">> => Error =:= null}};
        _ -> {error, <<"NOT_FOUND">>, <<"regra não encontrada"/utf8>>}
    end.

sample_facts(<<"schedule">>, _) -> #{<<"at">> => fmt(minute_now())};
sample_facts(<<"metric">>, #{<<"metric">> := M}) -> #{<<"metric">> => M, <<"value">> => maps:get(M, metrics_now(), null)};
sample_facts(<<"message">>, #{<<"connector">> := C}) ->
    case ana_db:one("SELECT event_id, payload FROM integration.inbox WHERE connector = $1 ORDER BY id DESC LIMIT 1", [C]) of
        {ok, #{<<"payload">> := P, <<"event_id">> := E}} when is_map(P) -> P#{<<"event_id">> => E, <<"connector">> => C};
        _ -> #{<<"connector">> => C}
    end;
sample_facts(_, _) -> #{}.
