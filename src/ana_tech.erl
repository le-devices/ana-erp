%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Technical actions (spec 077, T-077-01, T-077-02; plan §2.1).
%%
%% Every technical intervention is an action of the catalog (technical.action, data) carried out by a function of
%% the fixed map below — the catalog never points to arbitrary code; a test refuses a row without function and a
%% function without row. The risk decides the ceremony:
%%   low    — runs (the screen offers the undo action);
%%   medium — runs only when confirmed (the screen showed the consequence);
%%   high   — becomes a request a second person approves (frozen params, expires); with "act now" (on call) it runs
%%            and stays pending review, the approvers warned.
%% A company only makes an action stricter (technical.action_policy) and chooses the groups that may run it (none:
%% administrators). Everything is recorded in technical.action_run and in the audit (spec 024), through the API too.
-module(ana_tech).

-export([catalog/1, run/4, approve/3, reject/3, runs/1, pending/1, save_policy/3, handlers/0, risk_of/1, technical/1]).

-define(REQUEST_TTL_MIN, 30).
-define(RISKS, [<<"low">>, <<"medium">>, <<"high">>]).

%% ------------------------------------------------------------------ the fixed map: code → function
%% fun(Params, User) -> {ok, Result :: map()} | {error, Message :: binary()}.
-spec handlers() -> #{binary() => fun((map(), map()) -> {ok, map()} | {error, not_found | binary()})}.
handlers() ->
    #{<<"execution.stop">> => fun(#{<<"id">> := Id}, U) ->
          case ana_execution:command(Id, U, #{<<"action">> => <<"stop">>}) of
              ok -> {ok, #{stopped => Id}};
              {error, not_found} -> {error, not_found};
              {error, _} -> {error, <<"não foi possível parar a execução"/utf8>>}
          end
      end,
      <<"user.revoke_sessions">> => fun(#{<<"username">> := N}, U) -> plain(ana_admin:revoke_sessions(N, U)) end,
      <<"user.unlock">> => fun(#{<<"username">> := N}, U) -> plain(ana_admin:unlock_user(N, U)) end,
      <<"ip.unlock">> => fun(#{<<"ip">> := Ip}, U) -> plain(ana_admin:unlock_ip(Ip, U)) end,
      <<"integration.reprocess">> => fun(#{<<"kind">> := K, <<"id">> := Id}, U) -> plain(ana_integration:reprocess(K, Id, U)) end,
      <<"integration.discard">> => fun(#{<<"kind">> := K, <<"id">> := Id}, U) -> plain(ana_integration:discard(K, Id, U)) end,
      <<"api_client.release_breaker">> => fun(#{<<"client">> := C}, U) -> plain(ana_api:release_breaker(C, U)) end,
      <<"api_client.rotate_secret">> => fun(#{<<"client">> := C}, U) -> plain(ana_api:rotate_secret(C, U)) end,
      <<"api.rotate_keys">> => fun(_, U) -> plain(ana_api:rotate_keys(U)) end,
      <<"retention.purge">> => fun(_, U) ->
          case ana_retention:purge_now(U) of
              {ok, Detail} -> {ok, #{counts => json:decode(Detail)}};
              {error, E} -> {error, text(E)}
          end
      end,
      <<"health.check">> => fun(_, _) -> _ = ana_health:check_now(), plain(ana_observability:health()) end,
      <<"disk.sample">> => fun(_, _) -> ok = ana_disk:sample_now(), {ok, #{rates => ana_disk:rates()}} end,
      <<"checks.run">> => fun(P, U) ->
          Cat = case maps:get(<<"category">>, P, null) of C when is_binary(C), C =/= <<>> -> C; _ -> <<"all">> end,
          case ana_checks:run(Cat, U) of
              {error, unknown_category} -> {error, <<"categoria inexistente">>};
              {error, E} -> {error, text(E)};
              R -> plain(R)
          end
      end,
      <<"advice.run">> => fun(_, _) -> ok = ana_sql_stats:flush(), plain(ana_advisor:run()) end,
      <<"node.drain">> => fun(_, _) -> ana_ha:drain_soft(), {ok, #{node => ana_config:node_id(), draining => true}} end,
      <<"node.resume">> => fun(_, _) -> ana_ha:resume(), {ok, #{node => ana_config:node_id(), draining => false}} end,
      <<"parameter.set">> => fun set_parameter/2,
      %% Spec 077 (T-077-07): operation modes.
      <<"mode.read_only">> => fun(P, #{username := W}) -> mode(#{mode => <<"read_only">>, message => maps:get(<<"message">>, P),
                                                                  minutes => maps:get(<<"minutes">>, P, null)}, W) end,
      <<"mode.maintenance">> => fun(P, #{username := W}) ->
          mode(#{mode => <<"maintenance">>, message => maps:get(<<"message">>, P), minutes => maps:get(<<"minutes">>, P, null),
                 technical_group => maps:get(<<"technical_group">>, P, null)}, W) end,
      <<"mode.normal">> => fun(_, #{username := W}) -> {ok, _} = ana_mode:normal(W), {ok, ana_mode:current()} end,
      <<"integrations.pause_inbound">> => fun(_, #{username := W}) -> mode(#{inbound_paused => true}, W) end,
      <<"integrations.resume_inbound">> => fun(_, #{username := W}) ->
          R = mode(#{inbound_paused => false}, W), _ = (catch ana_integration:poke()), R end,
      <<"scheduler.suspend">> => fun(_, #{username := W}) -> mode(#{routines_suspended => true}, W) end,
      <<"scheduler.resume">> => fun(_, #{username := W}) -> mode(#{routines_suspended => false}, W) end}.

mode(Changes, Who) ->
    {ok, S} = ana_mode:set(Changes, Who, #{}),
    {ok, S#{message_shown => ana_mode:message()}}.

%% Spec 077 (T-077-04): a parameter changes with its reason, at a scope, possibly for a while.
set_parameter(P = #{<<"key">> := Key, <<"reason">> := Reason}, U) when byte_size(Reason) >= 3 ->
    Scope = case maps:get(<<"scope">>, P, <<"installation">>) of <<"node">> -> node; _ -> installation end,
    Opts = maps:merge(#{scope => Scope, reason => Reason, minutes => maps:get(<<"minutes">>, P, null)},
                      case maps:find(<<"node">>, P) of {ok, N} -> #{node => N}; error -> #{} end),
    case ana_settings:set(Key, maps:get(<<"value">>, P, null), U, Opts) of
        ok -> {ok, #{key => Key, value => maps:get(<<"value">>, P, null), scope => Scope}};
        {error, unknown_setting} -> {error, not_found};
        {error, {range, Min, Max}} ->
            {error, iolist_to_binary(io_lib:format("valor deve ser inteiro entre ~b e ~b", [Min, Max]))};
        {error, scope_not_allowed} -> {error, <<"este parâmetro não pode ser diferente por nó"/utf8>>}
    end;
set_parameter(_, _) -> {error, <<"diga o motivo da mudança (ao menos 3 letras)"/utf8>>}.

%% The answers of the functions the actions call, as an action's result.
plain({ok, V}) when is_map(V) -> {ok, V};
plain({error, not_found}) -> {error, not_found};
plain({error, M}) when is_binary(M) -> {error, M}.

text(B) when is_binary(B) -> B;
text(T) -> unicode:characters_to_binary(io_lib:format("~0tp", [T])).

%% ------------------------------------------------------------------ preconditions (fixed, by code)
precondition(<<"other_node_ready">>) ->
    Others = [N || N <- nodes(), case catch erpc:call(N, ana_ha, ready, [], 2000) of {true, _} -> true; _ -> false end],
    case Others of
        [] -> {error, <<"não há outro nó pronto: drenar o único nó tiraria o ERP do ar"/utf8>>};
        _ -> ok
    end;
precondition(Code) -> {error, <<"pré-condição desconhecida: "/utf8, Code/binary>>}.

%% ------------------------------------------------------------------ catalog and policy
%% The catalog for this user: each action with its effective risk and whether they may run it.
-spec catalog(map()) -> {ok, [map()]}.
catalog(User) ->
    {ok, Rows} = ana_db:rows(
        "SELECT a.code, a.name, a.description, a.params, a.preconditions, a.effect, a.impact, a.risk AS product_risk, "
        "  COALESCE(p.risk, a.risk) AS policy_risk, a.rehearsable, a.undo, a.success, a.in_rescue, a.area, "
        "  COALESCE(p.groups, '{}') AS groups, COALESCE(p.act_now, false) AS act_now "
        "FROM technical.action a LEFT JOIN technical.action_policy p ON p.code = a.code ORDER BY a.sequence, a.code", []),
    {ok, [R#{<<"risk">> => effective(R), <<"params">> => decode(maps:get(<<"params">>, R)),
             <<"allowed">> => allowed(User, R)} || R <- Rows]}.

effective(#{<<"product_risk">> := P, <<"policy_risk">> := Q}) -> max_risk(P, Q).

max_risk(A, B) ->
    case index(A) >= index(B) of true -> A; false -> B end.

index(R) -> length(lists:takewhile(fun(X) -> X =/= R end, ?RISKS)).

-spec risk_of(binary()) -> binary() | undefined.
risk_of(Code) ->
    case action(Code) of
        {ok, A} -> effective(A);
        _ -> undefined
    end.

%% The technical team: administrators, and the people of a group some action or the maintenance mode names.
-spec technical(map()) -> boolean().
technical(#{role := <<"admin">>}) -> true;
technical(#{username := U}) ->
    case ana_access:groups(U) of
        [] -> false;
        Mine ->
            case catch ana_db:one("SELECT EXISTS (SELECT 1 FROM technical.action_policy WHERE groups && $1::text[]) "
                                  "OR EXISTS (SELECT 1 FROM technical.operation_mode WHERE technical_group = ANY ($1::text[])) AS ok",
                                  [Mine]) of
                {ok, #{<<"ok">> := true}} -> true;
                _ -> false
            end
    end;
technical(_) -> false.

allowed(#{role := <<"admin">>}, #{<<"groups">> := []}) -> true;
allowed(_, #{<<"groups">> := []}) -> false;
allowed(#{username := U, role := Role}, #{<<"groups">> := Gs}) ->
    Role =:= <<"admin">> orelse lists:any(fun(G) -> lists:member(G, Gs) end, ana_access:groups(U));
allowed(_, _) -> false.

action(Code) ->
    case ana_db:one("SELECT a.code, a.name, a.params, a.preconditions, a.risk AS product_risk, "
                    "  COALESCE(p.risk, a.risk) AS policy_risk, COALESCE(p.groups, '{}') AS groups, "
                    "  COALESCE(p.act_now, false) AS act_now, a.effect "
                    "FROM technical.action a LEFT JOIN technical.action_policy p ON p.code = a.code WHERE a.code = $1",
                    [Code]) of
        {ok, A} when is_map(A) -> {ok, A#{<<"params">> => decode(maps:get(<<"params">>, A))}};
        _ -> {error, not_found}
    end.

%% A company makes an action stricter, never less strict than the product (RF-077-05).
-spec save_policy(binary(), map(), map()) -> {ok, map()} | {error, not_found | binary()}.
save_policy(Code, In, #{username := Who}) ->
    case action(Code) of
        {error, not_found} -> {error, not_found};
        {ok, #{<<"product_risk">> := Min}} ->
            Risk = maps:get(<<"risk">>, In, Min),
            Groups = maps:get(<<"groups">>, In, []),
            ActNow = maps:get(<<"act_now">>, In, false) =:= true,
            if
                not is_binary(Risk) orelse not is_list(Groups) -> {error, <<"risco e grupos inválidos"/utf8>>};
                true ->
                    case lists:member(Risk, ?RISKS) andalso index(Risk) >= index(Min) of
                        false -> {error, <<"a empresa só torna a ação mais rígida: o mínimo do produto é "/utf8, Min/binary>>};
                        true ->
                            {ok, _} = ana_db:exec(
                                "INSERT INTO technical.action_policy (code, risk, groups, act_now, updated_by) "
                                "VALUES ($1, $2, $3::text[], $4, $5) ON CONFLICT (code) DO UPDATE SET risk = EXCLUDED.risk, "
                                "groups = EXCLUDED.groups, act_now = EXCLUDED.act_now, updated_by = EXCLUDED.updated_by, "
                                "updated_at = now()", [Code, Risk, Groups, ActNow, Who]),
                            ana_admin:log(Who, <<"tech.policy">>, Code, null,
                                          #{risk => Risk, groups => Groups, act_now => ActNow}),
                            {ok, #{code => Code, risk => Risk, groups => Groups, act_now => ActNow}}
                    end
            end
    end.

%% ------------------------------------------------------------------ running
%% Opts: confirmed (medium), reason, origin. Returns {ok, Run} | {pending, Run} | {error, Code, Message}.
-spec run(binary(), map(), map(), map()) -> {ok, map()} | {pending, map()} | {error, binary(), binary()}.
run(Code, Params0, User, Opts) ->
    case action(Code) of
        {error, not_found} -> {error, <<"NOT_FOUND">>, <<"ação técnica inexistente"/utf8>>};
        {ok, A} ->
            case {allowed(User, A), check_params(maps:get(<<"params">>, A), Params0)} of
                {false, _} -> {error, <<"FORBIDDEN">>, <<"sem permissão para esta ação técnica"/utf8>>};
                {_, {error, M}} -> {error, <<"INVALID">>, M};
                {true, {ok, Params}} -> ceremony(A, Params, User, Opts)
            end
    end.

ceremony(A = #{<<"code">> := Code}, Params, User, Opts) ->
    %% Changing a parameter takes the parameter's own risk when it is the higher (D9).
    Risk = case {Code, Params} of
        {<<"parameter.set">>, #{<<"key">> := Key}} -> max_risk(effective(A), ana_settings:risk_of(Key));
        _ -> effective(A)
    end,
    case Risk of
        <<"low">> -> execute(Code, Risk, Params, User, Opts, null, <<"done">>, new);
        <<"medium">> ->
            case maps:get(confirmed, Opts, false) of
                true -> execute(Code, Risk, Params, User, Opts, null, <<"done">>, new);
                _ -> {error, <<"CONFIRMATION_REQUIRED">>, <<"confirme: "/utf8, (maps:get(<<"effect">>, A))/binary>>}
            end;
        <<"high">> ->
            case maps:get(<<"act_now">>, A) of
                true -> execute(Code, Risk, Params, User, Opts, null, <<"review">>, new);
                false -> request(Code, Risk, Params, User, Opts)
            end
    end.

check_params(Spec, In) when is_map(In) ->
    Known = [maps:get(<<"name">>, P) || P <- Spec],
    case [K || K <- maps:keys(In), not lists:member(K, Known)] of
        [_ | _] = Extra -> {error, <<"parâmetro desconhecido: "/utf8, (iolist_to_binary(lists:join(<<", ">>, Extra)))/binary>>};
        [] -> typed(Spec, In, #{})
    end;
check_params(_, _) -> {error, <<"parâmetros inválidos"/utf8>>}.

typed([], _, Acc) -> {ok, Acc};
typed([P = #{<<"name">> := N} | Rest], In, Acc) ->
    case {maps:get(N, In, null), maps:get(<<"required">>, P, false)} of
        {V, true} when V =:= null; V =:= <<>> -> {error, <<"falta "/utf8, (maps:get(<<"label">>, P, N))/binary>>};
        {V, _} when V =:= null; V =:= <<>> -> typed(Rest, In, Acc);
        {V, _} ->
            case typed_value(maps:get(<<"type">>, P), V, P) of
                {ok, T} -> typed(Rest, In, Acc#{N => T});
                error -> {error, <<(maps:get(<<"label">>, P, N))/binary, " inválido"/utf8>>}
            end
    end.

typed_value(<<"text">>, V, _) when is_binary(V), byte_size(V) =< 200 -> {ok, V};
typed_value(<<"integer">>, V, _) when is_integer(V) -> {ok, V};
typed_value(<<"integer">>, V, _) when is_binary(V) -> try {ok, binary_to_integer(V)} catch _:_ -> error end;
typed_value(<<"choice">>, V, #{<<"choices">> := Cs}) when is_binary(V) ->
    case lists:member(V, [C || [C | _] <- Cs]) of true -> {ok, V}; false -> error end;
typed_value(_, _, _) -> error.

request(Code, Risk, Params, #{username := Who}, Opts) ->
    {ok, R} = ana_db:one("INSERT INTO technical.action_run (code, params, risk, status, requested_by, origin, reason, expires_at, node) "
                         "VALUES ($1, $2::text::jsonb, $3, 'pending', $4, $5, $6, now() + make_interval(mins => $7), $8) "
                         "RETURNING id, code, params, risk, status, requested_by, requested_at, expires_at",
                         [Code, iolist_to_binary(json:encode(Params)), Risk, Who, origin(Opts), reason(Opts),
                          ?REQUEST_TTL_MIN, ana_config:node_id()]),
    ana_admin:log(Who, <<"tech.request">>, Code, null, Params),
    {pending, decode_run(R)}.

%% Request = new (a record is inserted) or the id of the approved request (its record is completed).
execute(Code, Risk, Params, User = #{username := Who}, Opts, Approver, Status, Request) ->
    {ok, A} = action(Code),
    case preconditions(maps:get(<<"preconditions">>, A)) of
        {error, M} -> {error, <<"PRECONDITION">>, M};
        ok ->
            Fun = maps:get(Code, handlers()),
            {Outcome, Result, Error} = try Fun(Params, User) of
                {ok, Res} -> {Status, Res, null};
                {error, not_found} -> {<<"failed">>, null, #{message => <<"não encontrado"/utf8>>, not_found => true}};
                {error, M} -> {<<"failed">>, null, #{message => M}}
            catch C:E -> {<<"failed">>, null, #{message => text({C, E})}}
            end,
            Returning = " RETURNING id, code, params, risk, status, requested_by, requested_at, approved_by, result, error",
            {ok, R} = case Request of
                new ->
                    ana_db:one(iolist_to_binary(
                        ["INSERT INTO technical.action_run (code, params, risk, status, requested_by, origin, reason, node, "
                         "  result, error, finished_at) "
                         "VALUES ($1, $2::text::jsonb, $3, $4, $5, $6, $7, $8, $9::text::jsonb, $10::text::jsonb, now())",
                         Returning]),
                        [Code, iolist_to_binary(json:encode(Params)), Risk, Outcome, Who, origin(Opts), reason(Opts),
                         ana_config:node_id(), json_or_null(redact(Result)), json_or_null(Error)]);
                Id ->
                    ana_db:one(iolist_to_binary(
                        ["UPDATE technical.action_run SET status = $2, approved_by = $3, decided_at = now(), node = $4, "
                         "  result = $5::text::jsonb, error = $6::text::jsonb, finished_at = now() WHERE id = $1", Returning]),
                        [Id, Outcome, Approver, ana_config:node_id(), json_or_null(redact(Result)), json_or_null(Error)])
            end,
            ana_admin:log(Who, <<"tech.", Code/binary>>, iolist_to_binary(json:encode(Params)), null,
                          #{status => Outcome, approved_by => Approver}),
            case Outcome of
                <<"failed">> when is_map_key(not_found, Error) -> {error, <<"NOT_FOUND">>, maps:get(message, Error)};
                <<"failed">> -> {error, <<"ACTION_FAILED">>, maps:get(message, Error)};
                %% The caller gets the whole result (a new secret, for instance); the record keeps it masked.
                _ -> {ok, (decode_run(R))#{<<"result">> => Result}}
            end
    end.

preconditions([]) -> ok;
preconditions([C | Rest]) ->
    case precondition(C) of
        ok -> preconditions(Rest);
        E -> E
    end.

%% A second person approves a pending request: never the one who asked; once; before it expires.
-spec approve(integer(), map(), map()) -> {ok, map()} | {error, binary(), binary()}.
approve(Id, User = #{username := Who}, Opts) ->
    case decide(Id, User) of
        {ok, #{<<"code">> := Code, <<"params">> := P, <<"risk">> := Risk}} ->
            execute(Code, Risk, decode(P), User, Opts, Who, <<"done">>, Id);
        E -> E
    end.

-spec reject(integer(), map(), binary()) -> {ok, map()} | {error, binary(), binary()}.
reject(Id, User = #{username := Who}, Reason) ->
    case decide(Id, User) of
        {ok, _} ->
            {ok, _} = ana_db:exec("UPDATE technical.action_run SET status = 'rejected', approved_by = $2, decided_at = now(), "
                                  "reason = COALESCE(reason || ' - ', '') || $3 WHERE id = $1", [Id, Who, Reason]),
            ana_admin:log(Who, <<"tech.reject">>, integer_to_binary(Id), null, null),
            {ok, #{id => Id, status => <<"rejected">>}};
        E -> E
    end.

decide(Id, User = #{username := Who}) ->
    _ = ana_db:exec("UPDATE technical.action_run SET status = 'expired' WHERE status = 'pending' AND expires_at < now()", []),
    case ana_db:one("SELECT id, code, params, risk, status, requested_by FROM technical.action_run WHERE id = $1", [Id]) of
        {ok, #{<<"status">> := <<"pending">>, <<"requested_by">> := Who}} ->
            {error, <<"FOUR_EYES">>, <<"quem pediu não aprova o próprio pedido (quatro olhos)"/utf8>>};
        {ok, #{<<"status">> := <<"pending">>, <<"code">> := Code} = R} ->
            {ok, A} = action(Code),
            case allowed(User, A) of
                true -> {ok, R};
                false -> {error, <<"FORBIDDEN">>, <<"sem permissão para esta ação técnica"/utf8>>}
            end;
        {ok, #{<<"status">> := S}} ->
            {error, <<"ACTION_DECIDED">>, <<"o pedido já foi decidido ou expirou ("/utf8, S/binary, ")">>};
        _ -> {error, <<"NOT_FOUND">>, <<"pedido não encontrado"/utf8>>}
    end.

-spec runs(map()) -> {ok, [map()]}.
runs(Q) ->
    Limit = max(1, min(500, maps:get(limit, Q, 100))),
    {ok, Rows} = ana_db:rows("SELECT r.id, r.code, a.name, r.params, r.risk, r.status, r.requested_by, r.requested_at, "
                             "  r.approved_by, r.decided_at, r.origin, r.reason, r.node, r.result, r.error, r.expires_at "
                             "FROM technical.action_run r JOIN technical.action a ON a.code = r.code "
                             "ORDER BY r.id DESC LIMIT $1", [Limit]),
    {ok, [decode_run(R) || R <- Rows]}.

-spec pending(map()) -> {ok, [map()]}.
pending(User) ->
    _ = ana_db:exec("UPDATE technical.action_run SET status = 'expired' WHERE status = 'pending' AND expires_at < now()", []),
    {ok, Rows} = ana_db:rows("SELECT r.id, r.code, a.name, a.effect, r.params, r.risk, r.status, r.requested_by, "
                             "  r.requested_at, r.expires_at, r.reason "
                             "FROM technical.action_run r JOIN technical.action a ON a.code = r.code "
                             "WHERE r.status IN ('pending', 'review') ORDER BY r.id", []),
    {ok, [(decode_run(R))#{<<"mine">> => maps:get(<<"requested_by">>, R) =:= maps:get(username, User)} || R <- Rows]}.

origin(Opts) -> maps:get(origin, Opts, <<"studio">>).
reason(Opts) ->
    case maps:get(reason, Opts, null) of
        R when is_binary(R), R =/= <<>> -> R;
        _ -> null
    end.

%% Secrets a result may carry (a rotated client secret) never go to the record.
redact(M) when is_map(M) ->
    maps:map(fun(K, V) ->
                 case re:run(to_bin(K), "secret|password|token|private", [caseless, {capture, none}]) of
                     match when V =/= null -> <<"***">>;
                     _ -> redact(V)
                 end
             end, M);
redact(L) when is_list(L) -> [redact(V) || V <- L];
redact(V) -> V.

to_bin(K) when is_atom(K) -> atom_to_binary(K);
to_bin(K) when is_binary(K) -> K;
to_bin(K) -> text(K).

json_or_null(null) -> null;
json_or_null(V) -> iolist_to_binary(json:encode(V)).

decode(V) when is_binary(V) -> json:decode(V);
decode(V) -> V.

decode_run(R) ->
    maps:map(fun(K, V) when K =:= <<"params">>; K =:= <<"result">>; K =:= <<"error">> -> decode(V);
                (_, V) -> V end, R).
