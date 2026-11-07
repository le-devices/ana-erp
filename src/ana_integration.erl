%% Reliable messaging (spec 017, RF-017-05, RNF-017-02; spec 062, D2/D4/D5).
%%
%% A committed write to the outbox or the inbox wakes this coordinator on every node at once (NOTIFY
%% "ana_wake" → ana_events); it finds the connectors with due messages and pokes one worker per connector
%% (ana_connector_worker), each with its own concurrency, so a slow connector never holds the others back.
%% An Erlang timer wakes it exactly when the next retry is due; a slower safety tick covers what an event
%% may miss (a lease that expired, a node that was down). Workers claim with FOR UPDATE SKIP LOCKED (no
%% message is processed by two nodes at once); a claimed message gets a lease; a node that dies leaves it
%% to be taken again when the lease ends (at least once, idempotent programs). Messages with the same
%% ordering_key go one at a time, in order. Failure → exponential backoff; out of attempts → dead
%% (reprocessed by an administrator).
-module(ana_integration).
-behaviour(gen_server).
-export([start_link/0, poke/0, reprocess/3, discard/3, messages/1, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([backoff_s/1, claim/3, run/2]).

-define(SAFETY_MS, 10000).
-define(LEASE, "10 minutes").

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Wake up now (a webhook arrived, an admin reprocessed).
poke() -> gen_server:cast(?MODULE, wake).

init([]) ->
    ok = ana_events:subscribe(<<"integration">>),
    erlang:send_after(2000, self(), tick),
    {ok, #{workers => #{}, timer => undefined, waking => false}}.

handle_call(_, _From, S) -> {reply, ok, S}.

handle_cast(wake, S) -> {noreply, wake_soon(S)};
handle_cast(_, S) -> {noreply, S}.

handle_info({ana_event, <<"integration">>, _}, S) -> {noreply, wake_soon(S)};
handle_info(wake, S) -> {noreply, dispatch(S#{waking := false})};
handle_info(tick, S) ->
    erlang:send_after(?SAFETY_MS, self(), tick),
    {noreply, dispatch(S)};
handle_info(due, S) -> {noreply, dispatch(S#{timer := undefined})};
handle_info({'DOWN', _, process, Pid, _}, S = #{workers := W}) ->
    {noreply, S#{workers := maps:filter(fun(_, P) -> P =/= Pid end, W)}};
handle_info(_, S) -> {noreply, S}.

%% A burst of writes becomes one look at the queues.
wake_soon(S = #{waking := true}) -> S;
wake_soon(S) -> self() ! wake, S#{waking := true}.

dispatch(S) ->
    case ana_ha:refusing() of
        true -> S;                                           % draining (spec 023): take nothing new
        false ->
            S1 = lists:foldl(fun poke_worker/2, S, safe(fun due_connectors/0, [])),
            arm(S1, safe(fun next_due_ms/0, null))
    end.

poke_worker(Connector, S = #{workers := W}) ->
    case maps:find(Connector, W) of
        {ok, Pid} -> ana_connector_worker:poke(Pid), S;
        error ->
            case ana_connector_sup:start_worker(Connector) of
                {ok, Pid} ->
                    _ = erlang:monitor(process, Pid),
                    ana_connector_worker:poke(Pid),
                    S#{workers := W#{Connector => Pid}};
                _ -> S
            end
    end.

%% The next retry in the future: an Erlang timer wakes the coordinator exactly then (D5).
arm(S = #{timer := T}, Ms) ->
    _ = T =/= undefined andalso erlang:cancel_timer(T),
    case Ms of
        null -> S#{timer := undefined};
        _ -> S#{timer := erlang:send_after(max(0, min(Ms, ?SAFETY_MS)), self(), due)}
    end.

due_connectors() ->
    {ok, Rows} = ana_db:rows(
        "SELECT connector FROM integration.outbox WHERE status IN ('pending', 'processing') AND next_at <= now() "
        "  AND (status = 'pending' OR lease_until < now()) "
        "UNION SELECT connector FROM integration.inbox WHERE status IN ('pending', 'processing') AND next_at <= now() "
        "  AND (status = 'pending' OR lease_until < now())", []),
    [C || #{<<"connector">> := C} <- Rows].

next_due_ms() ->
    {ok, #{<<"ms">> := Ms}} = ana_db:one(
        "SELECT (extract(epoch FROM least((SELECT min(next_at) FROM integration.outbox WHERE status = 'pending' AND next_at > now()), "
        "  (SELECT min(next_at) FROM integration.inbox WHERE status = 'pending' AND next_at > now())) - now()) * 1000)::bigint AS ms", []),
    Ms.

safe(F, Default) ->
    try F()
    catch C:R -> logger:warning("integration: ~0p:~0p", [C, R]), Default
    end.

%% Claimed for one connector (the worker of that connector calls it).
-spec claim(outbox | inbox, binary(), non_neg_integer()) -> [map()].
claim(_, _, N) when N =< 0 -> [];
claim(Table, Connector, N) ->
    try claim_rows(Table, Connector, N)
    catch C:R -> logger:warning("integration claim ~p failed: ~0p:~0p", [Table, C, R]), []
    end.

claim_rows(outbox, Connector, N) ->
    rows(ana_db:rows(
        "WITH c AS (SELECT o.id FROM integration.outbox o "
        "  WHERE o.connector = $2 AND o.next_at <= now() "
        "    AND (o.status = 'pending' OR (o.status = 'processing' AND o.lease_until < now())) "
        "    AND (o.ordering_key IS NULL OR NOT EXISTS (SELECT 1 FROM integration.outbox p WHERE p.connector = o.connector "
        "         AND p.ordering_key = o.ordering_key AND p.id < o.id AND p.status IN ('pending', 'processing'))) "
        "  ORDER BY o.next_at, o.id LIMIT $1 FOR UPDATE SKIP LOCKED) "
        "UPDATE integration.outbox o SET status = 'processing', attempts = o.attempts + 1, "
        "  lease_until = now() + interval '" ?LEASE "' FROM c WHERE o.id = c.id "
        "RETURNING o.id, o.connector, o.kind, o.ordering_key, o.payload, o.attempts, o.created_by", [N, Connector]));
claim_rows(inbox, Connector, N) ->
    rows(ana_db:rows(
        "WITH c AS (SELECT i.id FROM integration.inbox i "
        "  WHERE i.connector = $2 AND i.next_at <= now() "
        "    AND (i.status = 'pending' OR (i.status = 'processing' AND i.lease_until < now())) "
        "  ORDER BY i.next_at, i.id LIMIT $1 FOR UPDATE SKIP LOCKED) "
        "UPDATE integration.inbox i SET status = 'processing', attempts = i.attempts + 1, "
        "  lease_until = now() + interval '" ?LEASE "' FROM c WHERE i.id = c.id "
        "RETURNING i.id, i.connector, i.event_id, i.payload, i.headers, i.attempts", [N, Connector])).

rows({ok, R}) -> R;
rows(_) -> [].

%% Runs the connector's program as its run_as user (P14).
run(Kind, M = #{<<"id">> := Id, <<"connector">> := Name, <<"attempts">> := Attempt}) ->
    Field = case Kind of outbox -> <<"outbound_program">>; inbox -> <<"inbound_program">> end,
    {ok, C} = ana_db:one(
        "SELECT c.name, c.kind, c.auth, c.timeout_ms, c.rate_per_min, c.outbound_program, c.inbound_program, c.max_attempts, "
        "  c.active, c.options, u.username, u.role, u.active AS user_active "
        "FROM integration.connector c JOIN ana_system.app_user u ON u.username = c.run_as WHERE c.name = $1", [Name]),
    Result = case C of
        %% Spec 044: e-mail is delivered by the core itself (credentials never reach a program).
        #{<<"kind">> := <<"smtp">>, <<"active">> := true} when Kind =:= outbox -> email(C, M);
        #{<<"active">> := true, <<"user_active">> := true, Field := Program} when is_binary(Program) ->
            User = #{username => maps:get(<<"username">>, C), role => maps:get(<<"role">>, C)},
            Params = case Kind of
                outbox -> #{<<"message">> => maps:with([<<"id">>, <<"kind">>, <<"ordering_key">>, <<"payload">>,
                                                        <<"created_by">>], M#{<<"attempt">> => Attempt})};
                inbox -> #{<<"event">> => maps:with([<<"id">>, <<"event_id">>, <<"payload">>, <<"headers">>], M)}
            end,
            Conn = #{<<"name">> => Name, <<"options">> => maps:get(<<"options">>, C)},
            ana_execution:run(Program, Params#{<<"attempt">> => Attempt, <<"connector">> => Conn}, User,
                              #{origin => <<"internal">>});
        undefined -> {error, #{<<"message">> => <<"conector removido"/utf8>>}};
        _ -> {error, #{<<"message">> => <<"conector inativo, sem programa ou com usuário inativo"/utf8>>}}
    end,
    Max = case C of #{<<"max_attempts">> := X} -> X; _ -> 1 end,
    case Result of
        %% Over the connector's rate: back in the queue without spending an attempt.
        {later, Seconds} ->
            {ok, _} = ana_db:exec("UPDATE integration.outbox SET status = 'pending', lease_until = NULL, "
                                  "attempts = GREATEST(attempts - 1, 0), next_at = now() + make_interval(secs => $2) "
                                  "WHERE id = $1", [Id, Seconds]),
            ok;
        %% A permanent refusal (5xx, invalid address, attachment not allowed) is never retried.
        {error, #{<<"permanent">> := true} = E} -> finish(Kind, Id, Max, Max, {error, E});
        _ -> finish(Kind, Id, Attempt, Max, Result)
    end.

%% Spec 044: one e-mail of the outbox; attachments read with the permissions of who sent it (P14).
email(C, #{<<"payload">> := Msg, <<"created_by">> := Sender}) ->
    case ana_smtp:config(C) of
        {error, M} -> {error, #{<<"code">> => <<"SMTP_CONFIG">>, <<"message">> => M}};
        {ok, Cfg} ->
            case ana_connector:rate_ok(C) of
                false -> {later, 60 - erlang:system_time(second) rem 60};
                true ->
                    case attachments(Sender, maps:get(<<"attachments">>, Msg, [])) of
                        {ok, Atts} ->
                            case ana_smtp:deliver(Cfg, Msg, Atts) of
                                {ok, R} -> {ok, #{result => R}};
                                E -> E
                            end;
                        {error, Text} -> {error, #{<<"code">> => <<"ATTACHMENT">>, <<"message">> => Text, <<"permanent">> => true}}
                    end
            end
    end.

attachments(_, []) -> {ok, []};
attachments(Sender, List) when is_list(List) ->
    case ana_db:one("SELECT username, role FROM ana_system.app_user WHERE username = $1 AND active", [Sender]) of
        {ok, #{<<"username">> := U, <<"role">> := R}} ->
            User = #{username => U, role => R},
            Got = [case A of
                       #{<<"file">> := F} when is_integer(F) -> ana_files:get_binary(User, F, maps:get(<<"version">>, A, null));
                       _ -> {error, <<"anexo inválido"/utf8>>}
                   end || A <- List],
            case [E || {error, E} <- Got] of
                [E | _] when is_binary(E) -> {error, <<"anexo: "/utf8, E/binary>>};
                [_ | _] -> {error, <<"anexo indisponível para quem enviou"/utf8>>};
                [] ->
                    Files = [#{name => N, mime => Mi, data => D} || {ok, #{name := N, mime := Mi, data := D}} <- Got],
                    case lists:sum([byte_size(D) || #{data := D} <- Files]) =< ana_smtp:max_attachments() of
                        true -> {ok, Files};
                        false -> {error, <<"anexos acima de 10 MB"/utf8>>}
                    end
            end;
        _ -> {error, <<"quem enviou não é mais um usuário ativo"/utf8>>}
    end;
attachments(_, _) -> {error, <<"anexos inválidos"/utf8>>}.

finish(Kind, Id, _Attempt, _Max, {ok, #{result := R}}) ->
    {ok, _} = ana_db:exec(["UPDATE integration.", table(Kind), " SET status = 'done', done_at = now(), lease_until = NULL, "
                           "last_error = NULL, result = $2::text::jsonb WHERE id = $1"],
                          [Id, iolist_to_binary(json:encode(R))]),
    ok;
finish(Kind, Id, Attempt, Max, {error, E}) ->
    Msg = case E of
        #{<<"message">> := M} when is_binary(M) -> M;
        _ -> unicode:characters_to_binary(io_lib:format("~0p", [E]))
    end,
    Code = case E of #{<<"code">> := C} -> <<C/binary, ": ">>; _ -> <<>> end,
    Text = binary:part(<<Code/binary, Msg/binary>>, 0, min(2000, byte_size(Code) + byte_size(Msg))),
    {ok, _} = case Attempt >= Max of
        true ->
            logger:warning("integration ~p ~b dead after ~b attempt(s): ~ts", [Kind, Id, Attempt, Text]),
            ana_db:exec(["UPDATE integration.", table(Kind), " SET status = 'dead', lease_until = NULL, last_error = $2 "
                         "WHERE id = $1"], [Id, Text]);
        false ->
            ana_db:exec(["UPDATE integration.", table(Kind), " SET status = 'pending', lease_until = NULL, last_error = $2, "
                         "next_at = now() + make_interval(secs => $3) WHERE id = $1"], [Id, Text, backoff_s(Attempt)])
    end,
    ok.

table(outbox) -> "outbox";
table(inbox) -> "inbox".

%% 10 s, 20 s, 40 s … up to one hour.
-spec backoff_s(pos_integer()) -> pos_integer().
backoff_s(Attempt) -> min(3600, 10 bsl min(Attempt - 1, 16)).

%% ---------------------------------------------------------------- panel (RF-017-09)

kind_table(<<"outbox">>) -> {ok, "outbox"};
kind_table(<<"inbox">>) -> {ok, "inbox"};
kind_table(_) -> error.

reprocess(Kind, Id, #{username := Who}) ->
    case kind_table(Kind) of
        error -> {error, not_found};
        {ok, T} ->
            case ana_db:exec(["UPDATE integration.", T, " SET status = 'pending', attempts = 0, next_at = now(), "
                              "last_error = NULL WHERE id = $1 AND status IN ('dead', 'discarded')"], [Id]) of
                {ok, 0} -> {error, not_found};
                {ok, _} ->
                    ok = ana_admin:log(Who, <<"integration.reprocess">>, <<Kind/binary, ":", (integer_to_binary(Id))/binary>>,
                                       null, null),
                    poke(),
                    {ok, #{id => Id, status => <<"pending">>}}
            end
    end.

discard(Kind, Id, #{username := Who}) ->
    case kind_table(Kind) of
        error -> {error, not_found};
        {ok, T} ->
            case ana_db:exec(["UPDATE integration.", T, " SET status = 'discarded', lease_until = NULL "
                              "WHERE id = $1 AND status IN ('dead', 'pending')"], [Id]) of
                {ok, 0} -> {error, not_found};
                {ok, _} ->
                    ok = ana_admin:log(Who, <<"integration.discard">>, <<Kind/binary, ":", (integer_to_binary(Id))/binary>>,
                                       null, null),
                    {ok, #{id => Id, status => <<"discarded">>}}
            end
    end.

%% Filters: kind (outbox|inbox), status, connector.
messages(Q) ->
    Kind = maps:get(<<"kind">>, Q, <<"outbox">>),
    Status = maps:get(<<"status">>, Q, null),
    Connector = maps:get(<<"connector">>, Q, null),
    case kind_table(Kind) of
        error -> {error, not_found};
        {ok, "outbox"} ->
            ana_db:rows("SELECT id, connector, kind, ordering_key, status, attempts, next_at, last_error, created_by, "
                        "  created_at, done_at, payload, result FROM integration.outbox "
                        "WHERE ($1::text IS NULL OR status = $1) AND ($2::text IS NULL OR connector = $2) "
                        "ORDER BY id DESC LIMIT 200", [Status, Connector]);
        {ok, "inbox"} ->
            ana_db:rows("SELECT id, connector, event_id, status, attempts, next_at, last_error, received_at AS created_at, "
                        "  done_at, payload, headers, result FROM integration.inbox "
                        "WHERE ($1::text IS NULL OR status = $1) AND ($2::text IS NULL OR connector = $2) "
                        "ORDER BY id DESC LIMIT 200", [Status, Connector])
    end.

%% Per connector, last 24 h: calls, error rate, p95 latency, queues.
stats() ->
    ana_db:rows(
        "SELECT c.name, c.kind, c.active, "
        "  (SELECT count(*) FROM integration.call_log l WHERE l.connector = c.name AND l.at > now() - interval '24 hours') AS calls, "
        "  (SELECT round(100.0 * count(*) FILTER (WHERE l.status IS NULL OR l.status >= 400) / NULLIF(count(*), 0), 1) "
        "     FROM integration.call_log l WHERE l.connector = c.name AND l.at > now() - interval '24 hours') AS error_pct, "
        "  (SELECT percentile_disc(0.95) WITHIN GROUP (ORDER BY l.ms) FROM integration.call_log l "
        "     WHERE l.connector = c.name AND l.at > now() - interval '24 hours') AS p95_ms, "
        "  (SELECT count(*) FROM integration.outbox o WHERE o.connector = c.name AND o.status IN ('pending', 'processing')) AS out_pending, "
        "  (SELECT count(*) FROM integration.outbox o WHERE o.connector = c.name AND o.status = 'dead') AS out_dead, "
        "  (SELECT count(*) FROM integration.inbox i WHERE i.connector = c.name AND i.status IN ('pending', 'processing')) AS in_pending, "
        "  (SELECT count(*) FROM integration.inbox i WHERE i.connector = c.name AND i.status = 'dead') AS in_dead "
        "FROM integration.connector c ORDER BY c.name", []).
