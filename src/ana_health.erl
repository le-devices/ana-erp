%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Component health, alert rules and incidents (spec 019, RF-019-01, RF-019-08).
%%
%% Every 10 s each component is checked; only state changes are written
%% (health_event, P15). Then every active alert rule is evaluated on this node:
%% a component at or above a level, or a node metric beyond a threshold. The
%% condition must hold for the rule's whole window before an incident opens;
%% it closes as soon as the condition clears. A silenced incident is recorded
%% but notifies nobody until the silence ends. Notices, outbox messages and
%% incident writes wait in memory, in order, while the database is down; the
%% ANA_ALERT_WEBHOOK fallback is called at once. Every 5 min a metrics sample
%% is stored for charts.
-module(ana_health).
-behaviour(gen_server).

-export([start_link/0, state/0, history/1, incidents/1, check_now/0]).
-export([components_names/0, metric_names/0, metrics/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([holds/3, silenced/5]).

-define(EVERY_MS, 10000).
-define(SAMPLE_EVERY, 30).                    % ticks (5 min)
-define(METRICS, [<<"running">>, <<"failures_per_min">>, <<"memory_mb">>, <<"processes">>,
                  <<"db_waiting">>, <<"python_ready">>, <<"max_message_queue">>,
                  <<"wal_mb_per_hour">>, <<"temp_mb_per_hour">>]).        % spec 063 (D4): writing to disk
-define(DISK_METRICS, [<<"wal_mb_per_hour">>, <<"temp_mb_per_hour">>]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

state() -> gen_server:call(?MODULE, state, 5000).
check_now() -> gen_server:call(?MODULE, check, 15000).

components_names() -> [C || {C, _} <- components()].
metric_names() -> ?METRICS.

%% Spec 051: the node metrics of the last check, for the rules "when a metric passes a limit".
-spec metrics() -> map().
metrics() -> gen_server:call(?MODULE, metrics, 5000).

history(Hours) ->
    ana_db:rows("SELECT component, state, message, node, at FROM ana_system.health_event "
                "WHERE at > now() - make_interval(hours => $1) ORDER BY at DESC LIMIT 500", [Hours]).

incidents(Open) ->
    ana_db:rows("SELECT i.id, i.component, i.node, i.message, i.opened_at, i.closed_at, i.severity, i.silenced, "
                "  i.notified_at, i.rule_id, r.name AS rule, "
                "  (extract(epoch FROM COALESCE(i.closed_at, now()) - i.opened_at))::int AS seconds "
                "FROM ana_system.incident i LEFT JOIN ana_system.alert_rule r ON r.id = i.rule_id "
                "WHERE ($1 = false OR i.closed_at IS NULL) "
                "ORDER BY i.opened_at DESC LIMIT 200", [Open]).

init([]) ->
    erlang:send_after(3000, self(), tick),
    {ok, #{states => #{}, ticks => 0, pending => [], rules => [fallback_rule()], silences => [],
           firing => #{}, resumed => false, failures => undefined}}.

handle_call(state, _From, S = #{states := St}) -> {reply, St, S};
handle_call(metrics, _From, S) -> {reply, maps:get(last_metrics, S, #{}), S};
handle_call(check, _From, S) ->
    S2 = check(S),
    {reply, maps:get(states, S2), S2}.

handle_cast(_, S) -> {noreply, S}.

handle_info(tick, S = #{ticks := T}) ->
    erlang:send_after(?EVERY_MS, self(), tick),
    S2 = try check(S) catch C:R:St -> logger:warning("health check failed: ~0p:~0p ~0p", [C, R, St]), S end,
    _ = T rem ?SAMPLE_EVERY =:= 0 andalso is_pid(spawn(fun sample/0)),
    {noreply, S2#{ticks := T + 1}};
handle_info(_, S) -> {noreply, S}.

check(S = #{states := Old}) ->
    New = maps:from_list([{C, timed(F)} || {C, F} <- components()]),
    Node = ana_config:node_id(),
    Events = [{event, C, atom_to_binary(maps:get(state, V)), maps:get(message, V), Node, maps:get(at, V)}
              || {C, V} <- maps:to_list(New),
                 maps:get(state, V) =/= maps:get(state, maps:get(C, Old, #{state => unknown}))],
    [logger:notice("health: ~ts → ~ts (~ts)", [C, St, M]) || {event, C, St, M, _, _} <- Events],
    S1 = load(S#{states := New}, Node),
    {Metrics, S2} = metrics(S1),
    {Ops, S3} = evaluate(S2#{last_metrics => Metrics}, New, Metrics, Node),
    %% Writes wait in memory, in order, while the database itself is the one down.
    S3#{pending := flush(maps:get(pending, S3) ++ Events ++ Ops)}.

%% Rules and silences come from the database each tick; when it does not answer,
%% the last ones known keep working (the database being down is exactly when
%% alerts matter). Open incidents of this node are taken back once after a restart.
load(S = #{resumed := Resumed, firing := Firing}, Node) ->
    S1 = case {catch ana_db:rows("SELECT r.id, r.name, r.source, r.target, r.level, r.op, r.threshold::float8 AS threshold, r.threshold_value, "
                                "  r.window_s, r.severity, r.notify_studio, r.connector, r.recipients, c.kind AS connector_kind "
                                "FROM ana_system.alert_rule r LEFT JOIN integration.connector c ON c.name = r.connector "
                                "WHERE r.active ORDER BY r.id", []),
               catch ana_db:rows("SELECT rule_id, target, node, extract(epoch FROM starts_at - now())::float8 AS starts, "
                                 "  extract(epoch FROM ends_at - now())::float8 AS ends FROM ana_system.alert_silence "
                                 "WHERE ends_at > now()", [])} of
        {{ok, Rules}, {ok, Silences}} ->
            %% Silence times move to this node's clock (offsets from the database's now):
            %% a silence made a moment ago is in force even if the clocks differ.
            Here = wall(),
            S#{rules := Rules, silences := [Si#{<<"starts">> := Here + A, <<"ends">> := Here + B}
                                            || Si = #{<<"starts">> := A, <<"ends">> := B} <- Silences]};
        _ -> S
    end,
    case Resumed of
        true -> S1;
        false ->
            case catch ana_db:rows("SELECT rule_id, component, notified_at IS NOT NULL AS notified, silenced "
                                   "FROM ana_system.incident WHERE node = $1 AND closed_at IS NULL", [Node]) of
                {ok, Open} ->
                    Back = maps:from_list([{{null_id(R), C}, #{since => 0, open => true, notified => N, message => <<>>}}
                                           || #{<<"rule_id">> := R, <<"component">> := C, <<"notified">> := N} <- Open]),
                    S1#{resumed := true, firing := maps:merge(Back, Firing)};
                _ -> S1
            end
    end.

%% Sub-second: a whole-second clock would see a silence started this second as not yet begun.
wall() -> erlang:system_time(millisecond) / 1000.

null_id(null) -> null;
null_id(Id) -> Id.

%% Until the rules are read once, a red component still opens a critical incident.
fallback_rule() ->
    #{<<"id">> => null, <<"name">> => <<"Componente em falha"/utf8>>, <<"source">> => <<"health">>,
      <<"target">> => <<"*">>, <<"level">> => <<"red">>, <<"op">> => null, <<"threshold">> => null,
      <<"window_s">> => 0, <<"severity">> => <<"critical">>, <<"notify_studio">> => true,
      <<"connector">> => null, <<"connector_kind">> => null, <<"recipients">> => []}.

%% Node metrics the rules can watch (RF-019-08).
metrics(S = #{failures := Prev}) ->
    Now = erlang:monotonic_time(millisecond),
    Snap = catch ana_metrics:snapshot(),
    Ex = case Snap of #{executions := E} -> E; _ -> #{} end,
    Bad = lists:sum([maps:get(K, Ex, 0) || K <- [<<"error">>, <<"timeout">>, <<"aborted">>]]),
    PerMin = case Prev of
        {T0, B0} when Now > T0 -> max(0, Bad - B0) * 60000 / (Now - T0);
        _ -> 0
    end,
    Waiting = lists:sum([W || P <- [ana_db, ana_db_exec], #{waiting := W} <- [catch ana_db:status(P)]]),
    Ready = case catch ana_py_pool:status() of #{ready := R} -> R; _ -> 0 end,
    M = #{<<"running">> => maps:get(executions, catch_counters(), 0),
          <<"failures_per_min">> => PerMin,
          <<"memory_mb">> => erlang:memory(total) div (1024 * 1024),
          <<"processes">> => erlang:system_info(process_count),
          <<"db_waiting">> => Waiting,
          <<"python_ready">> => Ready,
          <<"max_message_queue">> => ana_core_view:max_queue()},          % spec 062 (D6): a queue growing
    {maps:merge(M, ana_disk:rates()), S#{failures := {Now, Bad}}}.

catch_counters() ->
    try ana_execution:counters() catch _:_ -> #{} end.

evaluate(S = #{rules := Rules, silences := Silences, firing := Firing}, States, Metrics, Node) ->
    Now = erlang:monotonic_time(second),
    Wall = erlang:system_time(second),
    Holding = maps:from_list(lists:append([holding(R, States, Metrics) || R <- Rules])),
    ById = maps:from_list([{maps:get(<<"id">>, R), R} || R <- Rules]),
    {Ops1, F1} = maps:fold(
        fun(Key = {Id, Target}, Msg, {Acc, F}) ->
            R = maps:get(Id, ById),
            Cur = maps:get(Key, F, #{since => Now, open => false, notified => false}),
            Quiet = silenced(Silences, Id, Target, Node, wall()),
            Window = maps:get(<<"window_s">>, R),
            {Ops, Next} = case Cur of
                #{open := false, since := Since} when Now - Since >= Window ->
                    {[{open, Id, maps:get(<<"severity">>, R), Target, Msg, Node, Wall, Quiet}
                      | notify(<<"opened">>, R, Target, Node, Msg, Wall, Quiet)],
                     Cur#{open := true, notified => not Quiet, rule => R}};
                #{open := true, notified := false} when not Quiet ->
                    {[{notified, Id, Target, Node} | notify(<<"opened">>, R, Target, Node, Msg, Wall, false)],
                     Cur#{notified := true}};
                _ -> {[], Cur}
            end,
            {Acc ++ Ops, F#{Key => Next#{message => Msg, rule => R}}}
        end, {[], Firing}, Holding),
    {Ops2, F2} = maps:fold(
        fun(Key = {Id, Target}, Cur, {Acc, F}) ->
            case maps:is_key(Key, Holding) of
                true -> {Acc, F};
                false ->
                    Closing = case Cur of
                        #{open := true} ->
                            Msg = closed_message(States, Metrics, Target, maps:get(message, Cur, <<>>)),
                            %% A rule turned off or removed still says its incident is over.
                            Notify = case {maps:get(notified, Cur, false), maps:get(Id, ById, maps:get(rule, Cur, undefined))} of
                                {true, R = #{}} -> notify(<<"closed">>, R, Target, Node, Msg, Wall, false);
                                _ -> []
                            end,
                            [{close, Id, Target, Node, Wall} | Notify];
                        _ -> []
                    end,
                    {Acc ++ Closing, maps:remove(Key, F)}
            end
        end, {[], F1}, F1),
    {Ops1 ++ Ops2, S#{firing := F2}}.

closed_message(States, Metrics, Target, Last) ->
    case {maps:get(Target, States, undefined), maps:get(Target, Metrics, undefined)} of
        {#{message := M}, _} -> M;
        {_, V} when is_number(V) -> fmt("~ts = ~ts", [Target, num(V)]);
        _ -> Last
    end.

%% The {RuleId, Target} pairs whose condition holds now, with a message.
holding(R = #{<<"source">> := <<"health">>, <<"target">> := T, <<"level">> := Level}, States, _M) ->
    Id = maps:get(<<"id">>, R),
    [{{Id, C}, Msg} || {C, #{state := St, message := Msg}} <- maps:to_list(States),
                       T =:= <<"*">> orelse T =:= C, holds(health, St, Level)];
holding(R = #{<<"source">> := <<"metric">>, <<"target">> := T, <<"op">> := Op, <<"threshold">> := Limit0}, _S, M) ->
    %% Spec 065: a limit taken from a company value is read from memory at each check.
    Limit = case maps:get(<<"threshold_value">>, R, null) of
        null -> Limit0;
        Name -> case ana_values:read(Name, #{}) of
                    {ok, #{value := X}} when is_number(X) -> X;
                    {ok, #{value := X}} when is_binary(X) -> try binary_to_float(X) catch _:_ -> try binary_to_integer(X) catch _:_ -> Limit0 end end;
                    _ -> Limit0
                end
    end,
    case maps:get(T, M, undefined) of
        V when is_number(V), is_number(Limit) ->
            case holds(Op, V, Limit) of
                true -> [{{maps:get(<<"id">>, R), T}, fmt("~ts = ~ts (regra: ~ts ~ts)~ts", [T, num(V), Op, num(Limit), who(T)])}];
                false -> []
            end;
        _ -> []
    end;
holding(_, _, _) -> [].

%% A jump in writing names what wrote it (spec 063, CA-063-04).
who(T) ->
    case lists:member(T, ?DISK_METRICS) of
        true -> case catch ana_disk:culprit_text() of
                    <<>> -> <<>>;
                    B when is_binary(B) -> <<" — "/utf8, B/binary>>;
                    _ -> <<>>
                end;
        false -> <<>>
    end.

-spec holds(atom() | binary(), term(), term()) -> boolean().
holds(health, St, <<"yellow">>) -> St =:= yellow orelse St =:= red;
holds(health, St, <<"red">>) -> St =:= red;
holds(<<">">>, V, L) -> V > L;
holds(<<">=">>, V, L) -> V >= L;
holds(<<"<">>, V, L) -> V < L;
holds(<<"<=">>, V, L) -> V =< L;
holds(_, _, _) -> false.

%% A silence matches when each of its filters is empty or equal, and it is in force now.
-spec silenced([map()], term(), binary(), binary(), number()) -> boolean().
silenced(Silences, Id, Target, Node, Now) ->
    lists:any(fun(#{<<"rule_id">> := R, <<"target">> := T, <<"node">> := N, <<"starts">> := A, <<"ends">> := B}) ->
                      (R =:= null orelse R =:= Id) andalso (T =:= null orelse T =:= Target)
                          andalso (N =:= null orelse N =:= Node) andalso A =< Now andalso Now < B
              end, Silences).

%% Destinations of a rule: a studio notice and/or a message to an integration
%% connector (webhook, e-mail gateway: retries and signatures come from spec 017).
notify(_Event, _R, _Target, _Node, _Msg, _At, true) -> [];
notify(Event, R, Target, Node, Msg, At, false) ->
    Name = maps:get(<<"name">>, R),
    Severity = maps:get(<<"severity">>, R),
    webhook(Event, R, Target, Node, Msg),
    Text = fmt("~ts ~ts: ~ts em ~ts — ~ts", [case Event of <<"opened">> -> <<"Alerta"/utf8>>;
                                                         _ -> <<"Encerrado"/utf8>> end,
                                           Name, Target, Node, Msg]),
    [{notice, Severity, Text} || maps:get(<<"notify_studio">>, R), Event =:= <<"opened">>]
    ++ [{outbox, C, <<"email">>,
         #{to => maps:get(<<"recipients">>, R), subject => <<"[ANA] ", Text/binary>>,
           text => <<Text/binary, "\r\n\r\nGravidade: "/utf8, Severity/binary, "\r\nRegra: ", Name/binary,
                     "\r\nVeja Administração → Saúde no Estúdio."/utf8>>}}
        || C <- [maps:get(<<"connector">>, R)], C =/= null, maps:get(<<"connector_kind">>, R, null) =:= <<"smtp">>]
    ++ [{outbox, C, <<"alert.", Event/binary>>,
         #{event => Event, rule => Name, rule_id => maps:get(<<"id">>, R), severity => Severity, target => Target,
           node => Node, message => Msg, at => At, recipients => maps:get(<<"recipients">>, R)}}
        || C <- [maps:get(<<"connector">>, R)], C =/= null, maps:get(<<"connector_kind">>, R, null) =/= <<"smtp">>].

flush([]) -> [];
flush([Op | Rest] = All) ->
    case catch write(Op) of
        ok -> flush(Rest);
        _ when length(All) > 1000 -> logger:warning("health: dropping ~b pending writes", [length(All) - 1000]),
                                     lists:sublist(All, 1000);
        _ -> All
    end.

write({event, Component, State, Msg, Node, At}) ->
    ok_or_error(ana_db:exec("INSERT INTO ana_system.health_event (component, state, message, node, at) "
                            "VALUES ($1, $2, $3, $4, to_timestamp($5))", [Component, State, Msg, Node, At]));
write({open, RuleId, Severity, Target, Msg, Node, At, Silenced}) ->
    ok_or_error(ana_db:exec("INSERT INTO ana_system.incident (rule_id, severity, component, node, message, opened_at, "
                            "  silenced, notified_at) "
                            "SELECT $1, $2, $3, $4, $5, to_timestamp($6), $7, CASE WHEN $7 THEN NULL ELSE to_timestamp($6) END "
                            "WHERE NOT EXISTS (SELECT 1 FROM ana_system.incident WHERE rule_id IS NOT DISTINCT FROM $1 "
                            "  AND component = $3 AND node = $4 AND closed_at IS NULL)",
                            [RuleId, Severity, Target, Node, Msg, At, Silenced]));
write({notified, RuleId, Target, Node}) ->
    ok_or_error(ana_db:exec("UPDATE ana_system.incident SET notified_at = now() WHERE rule_id IS NOT DISTINCT FROM $1 "
                            "AND component = $2 AND node = $3 AND closed_at IS NULL", [RuleId, Target, Node]));
write({close, RuleId, Target, Node, At}) ->
    ok_or_error(ana_db:exec("UPDATE ana_system.incident SET closed_at = to_timestamp($4) WHERE rule_id IS NOT DISTINCT FROM $1 "
                            "AND component = $2 AND node = $3 AND closed_at IS NULL", [RuleId, Target, Node, At]));
write({notice, Severity, Text}) ->
    ok_or_error(ana_db:exec("INSERT INTO ana_system.notice (kind, severity, message, link) "
                            "SELECT 'alert', $1, $2, '#/admin/health' WHERE NOT EXISTS (SELECT 1 FROM ana_system.notice "
                            "WHERE NOT read AND kind = 'alert' AND message = $2)",
                            [Severity, binary:part(Text, 0, min(byte_size(Text), 1900))]));
write({outbox, Connector, Kind, Payload}) ->
    ok_or_error(ana_db:exec("INSERT INTO integration.outbox (connector, kind, payload, created_by) "
                            "SELECT $1, $2, $3::text::jsonb, 'system' WHERE EXISTS "
                            "(SELECT 1 FROM integration.connector WHERE name = $1)",
                            [Connector, Kind, iolist_to_binary(json:encode(Payload))])).

ok_or_error({ok, _}) -> ok;
ok_or_error(E) -> E.

timed(F) ->
    T0 = erlang:monotonic_time(microsecond),
    R = try F() catch _:E -> {red, unicode:characters_to_binary(io_lib:format("falha na verificação: ~0p", [E]))} end,
    {State, Msg} = R,
    #{state => State, message => Msg, latency_ms => (erlang:monotonic_time(microsecond) - T0) / 1000,
      at => erlang:system_time(second)}.

components() ->
    [{<<"database">>, fun database/0},
     {<<"pool_core">>, fun() -> pool(ana_db) end},
     {<<"pool_programs">>, fun() -> pool(ana_db_exec) end},
     {<<"python">>, fun python/0},
     {<<"scheduler">>, fun scheduler/0},
     {<<"access_log">>, fun access_log/0},
     {<<"remote_systems">>, fun breakers/0},
     {<<"integrations">>, fun integrations/0},
     {<<"public_api">>, fun public_api/0}].

database() ->
    T0 = erlang:monotonic_time(millisecond),
    case catch ana_db:one("SELECT 1 AS ok", []) of
        {ok, #{<<"ok">> := 1}} ->
            Ms = erlang:monotonic_time(millisecond) - T0,
            if Ms > 1000 -> {yellow, fmt("banco lento: ~b ms para responder", [Ms])};
               true -> {green, fmt("responde em ~b ms", [Ms])}
            end;
        _ -> {red, <<"banco de dados não responde"/utf8>>}
    end.

pool(P) ->
    case catch ana_db:status(P) of
        #{free := F, busy := B, waiting := W, size := Size} ->
            if F + B =:= 0 -> {red, <<"nenhuma conexão aberta"/utf8>>};
               W > 0 -> {yellow, fmt("~b esperando conexão (~b em uso de ~b)", [W, B, Size])};
               true -> {green, fmt("~b em uso, ~b livres", [B, F])}
            end;
        _ -> {red, <<"pool indisponível"/utf8>>}
    end.

python() ->
    case catch ana_py_pool:status() of
        #{ready := R, warming := W, target := T} ->
            if T > 0, R + W =:= 0 -> {red, <<"nenhum processo Python disponível"/utf8>>};
               T > 0, R =:= 0 -> {yellow, <<"processos Python aquecendo (sob carga)"/utf8>>};
               true -> {green, fmt("~b pronto(s)", [R])}
            end;
        _ -> {red, <<"pool de Python indisponível"/utf8>>}
    end.

%% Somebody in the cluster must lead the scheduler (advisory lock held).
scheduler() ->
    case catch ana_db:one("SELECT count(*) AS n FROM pg_locks WHERE locktype = 'advisory' AND objid = 7741018 "
                          "AND granted", []) of
        {ok, #{<<"n">> := N}} when N > 0 -> {green, <<"há um líder no cluster"/utf8>>};
        {ok, _} -> {yellow, <<"nenhum nó lidera o agendamento agora"/utf8>>};
        _ -> {red, <<"não foi possível verificar"/utf8>>}
    end.

access_log() ->
    case catch ana_access_log:dropped() of
        0 -> {green, <<"sem descartes"/utf8>>};
        N when is_integer(N) -> {yellow, fmt("~b registro(s) de acesso descartado(s) por sobrecarga", [N])};
        _ -> {yellow, <<"registro de acessos indisponível"/utf8>>}
    end.

breakers() ->
    Open = [K || {K, _, _, _} = E <- (catch ets:tab2list(ana_breakers)), is_tuple(E), element(2, E) =/= closed],
    case Open of
        [] -> {green, <<"todos disponíveis"/utf8>>};
        _ -> {yellow, fmt("disjuntor aberto: ~ts", [lists:join(", ", [name(K) || K <- Open])])}
    end.

%% Spec 017: messages out of attempts wait for an administrator.
integrations() ->
    case catch ana_db:one("SELECT (SELECT count(*) FROM integration.outbox WHERE status = 'dead') + "
                          "(SELECT count(*) FROM integration.inbox WHERE status = 'dead') AS dead", []) of
        {ok, #{<<"dead">> := 0}} -> {green, <<"nenhuma mensagem parada"/utf8>>};
        {ok, #{<<"dead">> := N}} -> {yellow, fmt("~b mensagem(ns) de integração esgotaram as tentativas", [N])};
        _ -> {yellow, <<"não foi possível verificar"/utf8>>}
    end.

%% Spec 010 (RNF-010-10): API clients suspended by their circuit breaker.
public_api() ->
    case catch ana_db:rows("SELECT name FROM ana_system.api_client WHERE suspended_until > now() ORDER BY name LIMIT 20", []) of
        {ok, []} -> {green, <<"nenhum cliente suspenso"/utf8>>};
        {ok, Rows} -> {yellow, fmt("cliente(s) suspenso(s) por excesso de falhas: ~ts",
                                   [lists:join(", ", [N || #{<<"name">> := N} <- Rows])])};
        _ -> {yellow, <<"não foi possível verificar"/utf8>>}
    end.

name({remote, S}) -> S;
name({connector, S}) -> S;
name(K) -> io_lib:format("~0p", [K]).

%% Optional fallback webhook (ANA_ALERT_WEBHOOK): JSON POST at once, never blocks the checks.
webhook(Event, R, Target, Node, Msg) ->
    case ana_config:text("ANA_ALERT_WEBHOOK", "") of
        "" -> ok;
        Url ->
            Body = iolist_to_binary(json:encode(#{event => Event, rule => maps:get(<<"name">>, R),
                                                  severity => maps:get(<<"severity">>, R), component => Target,
                                                  node => Node, message => Msg, at => erlang:system_time(second)})),
            _ = spawn(fun() -> catch httpc:request(post, {Url, [], "application/json", Body},
                                                   [{timeout, 5000}], []) end),
            ok
    end.

num(V) when is_integer(V) -> integer_to_binary(V);
num(V) when is_float(V) -> float_to_binary(V, [{decimals, 2}, compact]).

sample() ->
    _ = ana_db:exec("INSERT INTO ana_system.metric_sample (node, metrics) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                    [ana_config:node_id(), ana_metrics:snapshot()]),
    ok.

fmt(F, A) -> unicode:characters_to_binary(io_lib:format(F, A)).
