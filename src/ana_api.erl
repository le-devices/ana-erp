%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Public API (spec 010): API clients, signed access tokens, limits, quotas, idempotency,
%% signed requests and the audit of public calls.
%%
%% Validation never touches the database on the hot path (RNF-010-11): clients, signing keys
%% and allowed origins live in ETS, invalidated on every node by NOTIFY "ana_api" (≤ 5 s,
%% RF-010-09) with a 30 s safety TTL. Every call runs as the client's robot user (P14); the
%% effective permission is exposed ∩ client scopes ∩ that user's role and groups (RF-010-05).
-module(ana_api).
-behaviour(gen_server).

-export([start_link/0, on_notify/2]).
-export([client/1, by_publishable/1, origin_allowed/1, check_secret/2, user_for/3, in_scope/2,
         create_client/2, update_client/3, rotate_secret/2, drop_secret/3, new_signing_secret/2, clients/0, calls/1]).
-export([issue/2, validate/1, rotate_keys/1, keys/0]).
-export([admit/2, release/0, record/1, outcome/2, release_breaker/2, technical/1, idempotency_begin/3, idempotency_end/4, nonce_ok/2, signature_ok/7,
         ip_allowed/2, public_mode/0, secure/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CLIENTS, ana_api_clients).
-define(META, ana_api_meta).
-define(RATE, ana_api_rate).
-define(TTL_MS, 30000).
-define(TOKEN_S, 600).
-define(LEEWAY_S, 30).
-define(AUD, <<"ana-api">>).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ana_listener, channel "ana_api": "client:<id>" | "keys" | "all".
on_notify(_Channel, <<"client:", Id/binary>>) ->
    _ = catch ets:delete(?CLIENTS, Id),
    _ = catch ets:delete(?RATE, {tripped, Id}),                % the row (suspended or released) decides now
    forget_origins();
on_notify(_Channel, <<"keys">>) -> _ = catch ets:delete(?META, keys), ok;
on_notify(_Channel, _) -> _ = catch ets:delete_all_objects(?CLIENTS), _ = catch ets:delete(?META, keys), forget_origins().

forget_origins() -> _ = catch ets:delete(?META, origins), ok.

notify(Payload) -> _ = ana_db:exec("SELECT pg_notify('ana_api', $1)", [Payload]), ok.

%% ---------------------------------------------------------------- clients (cache)

-spec client(term()) -> {ok, map()} | {error, not_found | unavailable}.
client(Id) when is_binary(Id) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?CLIENTS, Id) of
        [{_, C, At}] when Now - At < ?TTL_MS -> {ok, C};
        _ -> load_client(Id, Now)
    end;
client(_) -> {error, not_found}.

load_client(Id, Now) ->
    case ana_db:one(
            "SELECT c.client_id, c.name, c.kind, c.run_as, c.secret_hashes, c.publishable_hash, c.signing_ct, c.signing_nonce, "
            "  c.signing_tag, c.origins, c.redirect_uris, c.scopes, c.ip_allow::text[] AS ip_allow, c.rate_per_minute, "
            "  c.daily_quota, c.require_signature, "
            "  COALESCE(extract(epoch FROM c.suspended_until)::bigint, 0) AS suspended_until_s, "
            "  c.active AND u.active AND (c.expires_at IS NULL OR c.expires_at > now()) AS usable, u.role "
            "FROM ana_system.api_client c JOIN ana_system.app_user u ON u.username = c.run_as WHERE c.client_id = $1", [Id]) of
        {ok, #{} = R} ->
            Signing = case R of
                #{<<"signing_ct">> := Ct, <<"signing_nonce">> := N, <<"signing_tag">> := T} when is_binary(Ct) ->
                    case ana_vault:master_key() of
                        undefined -> undefined;
                        MK -> case ana_vault:decrypt(<<"api">>, Id, {base64:decode(Ct), base64:decode(N), base64:decode(T)}, MK) of
                                  {ok, K} -> K;
                                  error -> undefined
                              end
                    end;
                _ -> undefined
            end,
            C = (maps:without([<<"signing_ct">>, <<"signing_nonce">>, <<"signing_tag">>], R))#{signing => Signing},
            ets:insert(?CLIENTS, {Id, C, Now}),
            {ok, C};
        {error, _} -> {error, unavailable};               % spec 023: the database did not answer (503)
        _ -> {error, not_found}
    end.

-spec by_publishable(binary()) -> {ok, map()} | {error, not_found | unavailable}.
by_publishable(<<"ana_pk_", _/binary>> = Key) ->
    Hash = sha_hex(Key),
    case ana_db:one("SELECT client_id FROM ana_system.api_client WHERE publishable_hash = $1 AND kind = 'publishable'", [Hash]) of
        {ok, #{<<"client_id">> := Id}} -> client(Id);
        {error, _} -> {error, unavailable};
        _ -> {error, not_found}
    end;
by_publishable(_) -> {error, not_found}.

%% RF-010-08: exact origin of an active browser/publishable client (kept in memory).
-spec origin_allowed(binary()) -> boolean().
origin_allowed(Origin) ->
    Now = erlang:monotonic_time(millisecond),
    Set = case ets:lookup(?META, origins) of
        [{_, S, At}] when Now - At < ?TTL_MS -> S;
        _ ->
            S = case ana_db:rows("SELECT DISTINCT unnest(origins) AS o FROM ana_system.api_client WHERE active "
                                 "AND (expires_at IS NULL OR expires_at > now())", []) of
                {ok, Rows} -> [O || #{<<"o">> := O} <- Rows];
                _ -> []
            end,
            ets:insert(?META, {origins, S, Now}),
            S
    end,
    lists:member(Origin, Set).

%% Client secret (slow hash; up to 2 active for rotation without stopping).
-spec check_secret(map(), binary()) -> boolean().
check_secret(#{<<"secret_hashes">> := Hashes}, Secret) when is_binary(Secret) ->
    lists:any(fun(H) -> ana_security:verify_password(Secret, H) end, Hashes);
check_secret(_, _) -> false.

%% The user a public call runs as (the client's robot), with the client's limits.
-spec user_for(map(), binary(), binary()) -> map().
user_for(#{<<"client_id">> := Id, <<"run_as">> := U, <<"role">> := Role, <<"scopes">> := Scopes, <<"kind">> := Kind}, Auth, Ip) ->
    #{username => U, role => Role, api => #{client => Id, scopes => Scopes, kind => Kind},
      trace => #{ip => Ip, auth => Auth, key_id => null}}.     % the client is in api_call_log

%% RNF-010-07: exact names or a namespace prefix ("sales.*"); nothing broader.
-spec in_scope([binary()], binary()) -> boolean().
in_scope(Scopes, Program) ->
    lists:any(fun(S) ->
        case binary:split(S, <<".*">>) of
            [Ns, <<>>] when byte_size(S) > 2 -> binary:match(Program, <<Ns/binary, ".">>) =:= {0, byte_size(Ns) + 1};
            _ -> S =:= Program
        end
    end, Scopes).

%% ---------------------------------------------------------------- clients (administration)

-define(SCOPE_RX, "^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)*(\\.\\*)?$").

create_client(B, #{username := Who}) ->
    Kind = maps:get(<<"kind">>, B, <<"confidential">>),
    Id = <<"ana_ci_", (rand_alnum(24))/binary>>,
    case validate_fields(B, true) of
        {error, M} -> {error, M};
        ok when not (Kind =:= <<"confidential">> orelse Kind =:= <<"browser">> orelse Kind =:= <<"publishable">>) ->
            {error, <<"tipo deve ser confidential, browser ou publishable">>};
        ok ->
            {Secret, Hashes} = case Kind of
                <<"confidential">> -> S = <<"ana_sk_", (b64u(crypto:strong_rand_bytes(32)))/binary>>, {S, [ana_security:hash_password(S)]};
                _ -> {null, []}
            end,
            {Pk, PkHash} = case Kind of
                <<"publishable">> -> K = <<"ana_pk_", (b64u(crypto:strong_rand_bytes(24)))/binary>>, {K, sha_hex(K)};
                _ -> {null, null}
            end,
            case ana_db:exec(
                    "INSERT INTO ana_system.api_client (client_id, name, kind, run_as, secret_hashes, publishable_hash, origins, "
                    "  redirect_uris, scopes, ip_allow, rate_per_minute, daily_quota, require_signature, expires_at, created_by) "
                    "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::text[]::cidr[], $11, $12, $13, $14::text::timestamptz, $15)",
                    [Id, maps:get(<<"name">>, B), Kind, maps:get(<<"run_as">>, B), Hashes, PkHash,
                     maps:get(<<"origins">>, B, []), maps:get(<<"redirect_uris">>, B, []), maps:get(<<"scopes">>, B, []),
                     maps:get(<<"ip_allow">>, B, []), maps:get(<<"rate_per_minute">>, B, default_rate(Kind)),
                     maps:get(<<"daily_quota">>, B, null), maps:get(<<"require_signature">>, B, false) =:= true,
                     maps:get(<<"expires_at">>, B, null), Who]) of
                {ok, 1} ->
                    ana_admin:log(Who, <<"api.client.create">>, Id, null, maps:without([<<"run_as">>], B#{<<"kind">> => Kind})),
                    forget_origins(), notify(<<"client:", Id/binary>>),
                    {ok, #{client_id => Id, kind => Kind, client_secret => Secret, publishable_key => Pk}};
                {error, #{message := M}} -> {error, M}
            end
    end.

default_rate(<<"publishable">>) -> 60;
default_rate(_) -> 600.

update_client(Id, B, #{username := Who}) ->
    case validate_fields(B, false) of
        {error, M} -> {error, M};
        ok ->
            case ana_db:exec(
                    "UPDATE ana_system.api_client SET name = COALESCE($2, name), origins = COALESCE($3, origins), "
                    "  redirect_uris = COALESCE($4, redirect_uris), scopes = COALESCE($5, scopes), "
                    "  ip_allow = COALESCE($6::text[]::cidr[], ip_allow), rate_per_minute = COALESCE($7, rate_per_minute), "
                    "  daily_quota = CASE WHEN $8::boolean THEN $9 ELSE daily_quota END, "
                    "  require_signature = COALESCE($10, require_signature), active = COALESCE($11, active), "
                    "  expires_at = CASE WHEN $12::boolean THEN $13::text::timestamptz ELSE expires_at END, updated_at = now() "
                    "WHERE client_id = $1",
                    [Id, maps:get(<<"name">>, B, null), maps:get(<<"origins">>, B, null), maps:get(<<"redirect_uris">>, B, null),
                     maps:get(<<"scopes">>, B, null), maps:get(<<"ip_allow">>, B, null), maps:get(<<"rate_per_minute">>, B, null),
                     maps:is_key(<<"daily_quota">>, B), maps:get(<<"daily_quota">>, B, null),
                     maps:get(<<"require_signature">>, B, null), maps:get(<<"active">>, B, null),
                     maps:is_key(<<"expires_at">>, B), maps:get(<<"expires_at">>, B, null)]) of
                {ok, 1} ->
                    ana_admin:log(Who, <<"api.client.update">>, Id, null, B),
                    _ = catch ets:delete(?CLIENTS, Id), forget_origins(), notify(<<"client:", Id/binary>>),
                    {ok, #{client_id => Id}};
                {ok, 0} -> {error, not_found};
                {error, #{message := M}} -> {error, M}
            end
    end.

validate_fields(B, Creating) ->
    Checks = [{<<"name">>, fun(V) -> is_binary(V) andalso byte_size(V) >= 2 andalso byte_size(V) =< 120 end, Creating},
              {<<"run_as">>, fun(V) -> is_binary(V) andalso robot(V) end, Creating},
              {<<"origins">>, fun(V) -> is_list(V) andalso lists:all(fun valid_origin/1, V) end, false},
              {<<"redirect_uris">>, fun(V) -> is_list(V) andalso lists:all(fun valid_redirect/1, V) end, false},
              {<<"scopes">>, fun(V) -> is_list(V) andalso lists:all(fun(S) -> is_binary(S) andalso re:run(S, ?SCOPE_RX) =/= nomatch end, V) end, false},
              {<<"ip_allow">>, fun(V) -> is_list(V) andalso lists:all(fun(C) -> parse_cidr(C) =/= error end, V) end, false},
              {<<"rate_per_minute">>, fun(V) -> is_integer(V) andalso V >= 1 andalso V =< 1000000 end, false},
              {<<"daily_quota">>, fun(V) -> V =:= null orelse (is_integer(V) andalso V > 0) end, false}],
    Bad = [K || {K, F, Required} <- Checks,
                case maps:find(K, B) of {ok, V} -> not F(V); error -> Required end],
    case Bad of
        [] -> ok;
        [<<"run_as">> | _] -> {error, <<"run_as deve ser um usuário robô ativo (P14: toda chamada tem dono)"/utf8>>};
        [<<"origins">> | _] -> {error, <<"origens: https://nome[:porta] exato (http só para localhost)"/utf8>>};
        [<<"scopes">> | _] -> {error, <<"escopos: nome do programa ou prefixo de módulo (ex.: sales.*)"/utf8>>};
        [K | _] -> {error, <<"campo inválido: "/utf8, K/binary>>}
    end.

robot(U) ->
    case ana_db:one("SELECT 1 AS ok FROM ana_system.app_user WHERE username = $1 AND active AND kind = 'robot'", [U]) of
        {ok, #{}} -> true;
        _ -> false
    end.

valid_origin(<<"https://", _/binary>> = O) -> re:run(O, <<"^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$">>) =/= nomatch;
valid_origin(<<"http://localhost", _/binary>> = O) -> re:run(O, <<"^http://localhost(:[0-9]{1,5})?$">>) =/= nomatch;
valid_origin(_) -> false.

valid_redirect(<<"https://", _/binary>> = U) -> byte_size(U) =< 500;
valid_redirect(<<"http://localhost", _/binary>> = U) -> byte_size(U) =< 500;
valid_redirect(_) -> false.

rotate_secret(Id, #{username := Who}) ->
    S = <<"ana_sk_", (b64u(crypto:strong_rand_bytes(32)))/binary>>,
    %% Keeps the newest previous secret: both work until drop_secret (rotation without stopping).
    case ana_db:exec("UPDATE ana_system.api_client SET secret_hashes = ARRAY[$2::text] || secret_hashes[1:1], updated_at = now() "
                     "WHERE client_id = $1 AND kind = 'confidential'", [Id, ana_security:hash_password(S)]) of
        {ok, 1} ->
            ana_admin:log(Who, <<"api.client.rotate_secret">>, Id, null, null),
            _ = catch ets:delete(?CLIENTS, Id), notify(<<"client:", Id/binary>>),
            {ok, #{client_id => Id, client_secret => S, active_secrets => 2}};
        _ -> {error, not_found}
    end.

drop_secret(Id, Old, #{username := Who}) when Old =:= true ->
    case ana_db:exec("UPDATE ana_system.api_client SET secret_hashes = secret_hashes[1:1], updated_at = now() WHERE client_id = $1",
                     [Id]) of
        {ok, 1} ->
            ana_admin:log(Who, <<"api.client.drop_secret">>, Id, null, null),
            _ = catch ets:delete(?CLIENTS, Id), notify(<<"client:", Id/binary>>),
            {ok, #{client_id => Id, active_secrets => 1}};
        _ -> {error, not_found}
    end;
drop_secret(_, _, _) -> {error, <<"confirme a remoção do segredo anterior"/utf8>>}.

%% RF-010-06: key for signed requests (shown once; stored encrypted in the vault).
new_signing_secret(Id, #{username := Who}) ->
    case ana_vault:enabled() of
        false -> {error, <<"cofre desligado: defina ANA_MASTER_KEY"/utf8>>};
        true ->
            K = crypto:strong_rand_bytes(32),
            {C, N, T} = ana_vault:encrypt(<<"api">>, Id, K),
            case ana_db:exec("UPDATE ana_system.api_client SET signing_ct = $2, signing_nonce = $3, signing_tag = $4, "
                             "updated_at = now() WHERE client_id = $1", [Id, C, N, T]) of
                {ok, 1} ->
                    ana_admin:log(Who, <<"api.client.signing_secret">>, Id, null, null),
                    _ = catch ets:delete(?CLIENTS, Id), notify(<<"client:", Id/binary>>),
                    {ok, #{client_id => Id, signing_secret => binary:encode_hex(K, lowercase)}};
                _ -> {error, not_found}
            end
    end.

clients() ->
    ana_db:rows("SELECT c.client_id, c.name, c.kind, c.run_as, cardinality(c.secret_hashes) AS secrets, "
                "  c.publishable_hash IS NOT NULL AS publishable, c.signing_ct IS NOT NULL AS signing, c.origins, c.redirect_uris, "
                "  c.scopes, c.ip_allow::text[] AS ip_allow, c.rate_per_minute, c.daily_quota, c.require_signature, c.active, "
                "  c.expires_at, c.created_by, c.created_at, "
                "  CASE WHEN c.suspended_until > now() THEN c.suspended_until END AS suspended_until, "
                "  (SELECT count(*) FROM ana_system.api_breaker_event e WHERE e.client_id = c.client_id "
                "     AND e.opened_at > now() - interval '7 days') AS breaker_openings, "
                "  COALESCE((SELECT calls FROM ana_system.api_usage u WHERE u.client_id = c.client_id AND u.day = (now() AT TIME ZONE 'UTC')::date), 0) AS today "
                "FROM ana_system.api_client c ORDER BY c.name", []).

calls(Filters) ->
    ana_db:rows("SELECT at, client_id, username, auth, ip, program, status, duration_ms, idempotency_key FROM ana_system.api_call_log "
                "WHERE ($1::text IS NULL OR client_id = $1) ORDER BY id DESC LIMIT 500", [maps:get(client, Filters, null)]).

%% ---------------------------------------------------------------- tokens (RNF-010-02)

%% Compact JWS, algorithm fixed (EdDSA): the token never chooses it.
-spec issue(map(), [binary()]) -> {ok, map()} | {error, binary()}.
issue(#{<<"client_id">> := Id, <<"scopes">> := Allowed}, Requested) ->
    Scopes = case Requested of [] -> Allowed; _ -> [S || S <- Requested, lists:member(S, Allowed)] end,
    case active_key() of
        {ok, Kid, Priv} ->
            Now = erlang:system_time(second),
            H = b64u(iolist_to_binary(json:encode(#{<<"alg">> => <<"EdDSA">>, <<"kid">> => Kid, <<"typ">> => <<"at+jwt">>}))),
            P = b64u(iolist_to_binary(json:encode(#{<<"iss">> => ana_instance:name(), <<"aud">> => ?AUD, <<"sub">> => Id,
                                                     <<"scp">> => Scopes, <<"iat">> => Now, <<"exp">> => Now + ?TOKEN_S,
                                                     <<"jti">> => b64u(crypto:strong_rand_bytes(12))}))),
            Sig = b64u(crypto:sign(eddsa, none, <<H/binary, ".", P/binary>>, [Priv, ed25519])),
            {ok, #{access_token => <<H/binary, ".", P/binary, ".", Sig/binary>>, token_type => <<"Bearer">>,
                   expires_in => ?TOKEN_S, scope => iolist_to_binary(lists:join(<<" ">>, Scopes))}};
        E -> E
    end.

-spec validate(binary()) -> {ok, map()} | {error, invalid}.
validate(Token) ->
    try check(binary:split(Token, <<".">>, [global]))
    catch _:_ -> {error, invalid}
    end.

check([H, P, S]) ->
    #{<<"alg">> := <<"EdDSA">>, <<"kid">> := Kid} = json:decode(b64d(H)),
    {ok, Pub} = public_key(Kid),
    true = crypto:verify(eddsa, none, <<H/binary, ".", P/binary>>, b64d(S), [Pub, ed25519]),
    #{<<"iss">> := Iss, <<"aud">> := ?AUD, <<"sub">> := Sub, <<"exp">> := Exp, <<"iat">> := Iat} = C = json:decode(b64d(P)),
    Now = erlang:system_time(second),
    true = Iss =:= ana_instance:name() andalso is_binary(Sub),
    true = Exp + ?LEEWAY_S >= Now andalso Iat - ?LEEWAY_S =< Now,
    {ok, C}.

keys() -> load_keys().

load_keys() ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?META, keys) of
        [{_, K, At}] when Now - At < ?TTL_MS -> K;
        _ ->
            {ok, Rows} = ana_db:rows("SELECT kid, public_key, active, ciphertext, nonce, tag FROM ana_system.signing_key "
                                     "WHERE active OR retired_at > now() - interval '1 day'", []),
            K = #{pub => maps:from_list([{Kid, base64:decode(P)} || #{<<"kid">> := Kid, <<"public_key">> := P} <- Rows]),
                  active => case [R || R = #{<<"active">> := true} <- Rows] of
                      [#{<<"kid">> := Kid, <<"ciphertext">> := C, <<"nonce">> := N, <<"tag">> := T}] ->
                          case ana_vault:master_key() of
                              undefined -> undefined;
                              MK -> case ana_vault:decrypt(<<"signing_key">>, Kid, {base64:decode(C), base64:decode(N), base64:decode(T)}, MK) of
                                        {ok, Priv} -> {Kid, Priv};
                                        error -> undefined
                                    end
                          end;
                      _ -> undefined
                  end},
            ets:insert(?META, {keys, K, Now}),
            K
    end.

public_key(Kid) ->
    case maps:find(Kid, maps:get(pub, load_keys())) of
        {ok, P} -> {ok, P};
        error -> forget_keys_once(), maps:find(Kid, maps:get(pub, load_keys()))
    end.

%% An unknown kid may be a key just created on another node: reload at most once a second.
forget_keys_once() ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?META, keys_reload) of
        [{_, At}] when Now - At < 1000 -> ok;
        _ -> ets:insert(?META, {keys_reload, Now}), _ = ets:delete(?META, keys), ok
    end.

active_key() ->
    case maps:get(active, load_keys()) of
        {Kid, Priv} -> {ok, Kid, Priv};
        undefined ->
            case rotate_keys(#{username => <<"system">>}) of
                {ok, _} -> _ = ets:delete(?META, keys), case maps:get(active, load_keys()) of {Kid, Priv} -> {ok, Kid, Priv}; _ -> {error, <<"sem chave de assinatura">>} end;
                E -> E
            end
    end.

%% New active key; the previous one keeps validating its tokens (rotation without stopping).
-spec rotate_keys(map()) -> {ok, map()} | {error, binary()}.
rotate_keys(#{username := Who}) ->
    case ana_vault:enabled() of
        false -> {error, <<"cofre desligado: defina ANA_MASTER_KEY para assinar tokens"/utf8>>};
        true ->
            {Pub, Priv} = crypto:generate_key(eddsa, ed25519),
            Kid = b64u(crypto:strong_rand_bytes(9)),
            {C, N, T} = ana_vault:encrypt(<<"signing_key">>, Kid, Priv),
            {ok, _} = ana_db:transaction(fun(Conn) ->
                {ok, _} = ana_db:query(Conn, "UPDATE ana_system.signing_key SET active = false, retired_at = now() WHERE active", []),
                {ok, _} = ana_db:query(Conn, "INSERT INTO ana_system.signing_key (kid, public_key, ciphertext, nonce, tag) "
                                             "VALUES ($1, $2, $3, $4, $5)", [Kid, Pub, C, N, T]),
                {ok, _} = ana_db:query(Conn, "SELECT pg_notify('ana_api', 'keys')", []),
                {ok, done}
            end),
            ana_admin:log(Who, <<"api.keys.rotate">>, Kid, null, null),
            {ok, #{kid => Kid}}
    end.

%% ---------------------------------------------------------------- limits (RNF-010-04, 08)

%% {ok} | {error, suspended, RetryAfterS} | {error, rate, RetryAfterS} | {error, quota} | {error, overload}.
%% release/0 after an ok.
-spec admit(map(), binary()) -> ok | {error, suspended | rate, pos_integer()} | {error, quota} | {error, overload}.
admit(#{<<"client_id">> := Id} = C, Ip) ->
    NowS = erlang:system_time(second),
    case suspended_until(C) of
        Until when Until > NowS -> {error, suspended, Until - NowS};
        _ -> admit(C, Ip, NowS, Id)
    end.

%% The client row (cache, every node) or this node's own trip while the NOTIFY travels.
suspended_until(#{<<"client_id">> := Id} = C) ->
    Local = case ets:lookup(?RATE, {tripped, Id}) of [{_, U}] -> U; [] -> 0 end,
    max(Local, maps:get(<<"suspended_until_s">>, C, 0)).

admit(#{<<"rate_per_minute">> := Rate, <<"daily_quota">> := Quota}, _Ip, NowS, Id) ->
    Min = NowS div 60,
    case ets:update_counter(?RATE, {rate, Id, Min}, 1, {{rate, Id, Min}, 0}) of
        N when N > Rate -> {error, rate, 60 - (NowS rem 60)};
        _ ->
            Day = calendar:system_time_to_rfc3339(NowS, [{unit, second}]),
            Today = binary:part(list_to_binary(Day), 0, 10),
            Used = ets:update_counter(?RATE, {quota, Id, Today}, 1, {{quota, Id, Today}, 0}) + base_usage(Id, Today),
            case Quota of
                Q when is_integer(Q), Used > Q -> {error, quota};
                _ ->
                    Max = max(1, ana_settings:get(exec_max) * share() div 100),
                    case ets:update_counter(?RATE, inflight, 1, {inflight, 0}) of
                        F when F > Max -> _ = ets:update_counter(?RATE, inflight, -1), {error, overload};
                        _ -> ok
                    end
            end
    end.

-spec release() -> ok.
release() -> _ = ets:update_counter(?RATE, inflight, -1, {inflight, 0}), ok.

%% ---------------------------------------------------------------- circuit breaker (RNF-010-10)

%% Technical failures are the platform's or the program's fault (internal error, time out),
%% never the caller's (invalid parameter, forbidden, business refusal): only those count.
-spec technical(binary()) -> boolean().
technical(Code) -> lists:member(Code, [<<"TIMEOUT">>, <<"INTERNAL">>, <<"EXCEPTION">>, <<"CPU_LIMIT">>, <<"MEMORY">>,
                                       <<"SYNTAX">>, <<"SQL">>, <<"PROTOCOL">>, <<"PROCESS_EXITED">>, <<"UNAVAILABLE">>]).

%% Every finished public call; per-minute buckets of this node, the last two minutes decide.
-spec outcome(binary(), boolean()) -> ok.
outcome(Id, Failed) ->
    Min = erlang:system_time(second) div 60,
    _ = ets:update_counter(?RATE, {calls, Id, Min}, 1, {{calls, Id, Min}, 0}),
    case Failed of
        false -> ok;
        true ->
            _ = ets:update_counter(?RATE, {fails, Id, Min}, 1, {{fails, Id, Min}, 0}),
            Count = fun(K) -> lists:sum([N || M <- [Min - 1, Min], {_, N} <- ets:lookup(?RATE, {K, Id, M})]) end,
            Fails = Count(fails),
            Calls = Count(calls),
            case Fails >= ana_settings:get(api_breaker_failures)
                 andalso Fails * 100 >= ana_settings:get(api_breaker_ratio) * Calls of
                true -> trip(Id, Fails, Calls);
                false -> ok
            end
    end.

%% One opening per period on the whole cluster: the conditional UPDATE decides who records it.
trip(Id, Fails, Calls) ->
    NowS = erlang:system_time(second),
    Until = NowS + ana_settings:get(api_breaker_open_s),
    case ets:insert_new(?RATE, {{tripping, Id}, NowS}) of
        false -> ok;
        true ->
            ets:insert(?RATE, {{tripped, Id}, Until}),
            forget_counts(Id),
            _ = spawn(fun() ->
                try record_trip(Id, Fails, Calls, Until) after ets:delete(?RATE, {tripping, Id}) end
            end),
            ok
    end.

record_trip(Id, Fails, Calls, Until) ->
    case ana_db:one("UPDATE ana_system.api_client SET suspended_until = to_timestamp($2) WHERE client_id = $1 "
                    "AND (suspended_until IS NULL OR suspended_until < now()) RETURNING name", [Id, Until]) of
        {ok, #{<<"name">> := Name}} ->
            _ = ana_db:exec("INSERT INTO ana_system.api_breaker_event (client_id, node, failures, calls, until) "
                            "VALUES ($1, $2, $3, $4, to_timestamp($5))", [Id, ana_config:node_id(), Fails, Calls, Until]),
            Msg = unicode:characters_to_binary(io_lib:format(
                "API pública: cliente ~ts suspenso por ~b s (~b falhas técnicas em ~b chamadas)",
                [Name, Until - erlang:system_time(second), Fails, Calls])),
            _ = ana_db:exec("INSERT INTO ana_system.notice (kind, severity, message, link) "
                            "VALUES ('api_breaker', 'serious', $1, '#/admin/publicapi')", [Msg]),
            logger:warning("~ts", [Msg]),
            notify(<<"client:", Id/binary>>);
        _ -> ok
    end.

forget_counts(Id) ->
    _ = ets:match_delete(?RATE, {{calls, Id, '_'}, '_'}),
    _ = ets:match_delete(?RATE, {{fails, Id, '_'}, '_'}),
    ok.

%% By hand, before the period ends (Administração → API pública).
-spec release_breaker(binary(), map()) -> {ok, map()} | {error, not_found}.
release_breaker(Id, #{username := Who}) ->
    case ana_db:one("UPDATE ana_system.api_client SET suspended_until = NULL WHERE client_id = $1 RETURNING client_id", [Id]) of
        {ok, #{<<"client_id">> := _}} ->
            _ = ana_db:exec("UPDATE ana_system.api_breaker_event SET released_by = $2, released_at = now() "
                            "WHERE client_id = $1 AND released_at IS NULL AND until > now()", [Id, Who]),
            ana_admin:log(Who, <<"api.breaker.release">>, Id, null, null),
            notify(<<"client:", Id/binary>>),
            {ok, #{released => Id}};
        _ -> {error, not_found}
    end.

share() ->
    case catch list_to_integer(ana_config:text("ANA_PUBLIC_EXEC_SHARE", "50")) of
        N when is_integer(N), N >= 1, N =< 100 -> N;
        _ -> 50
    end.

base_usage(Id, Today) ->
    case ets:lookup(?RATE, {quota_db, Id, Today}) of
        [{_, N}] -> N;
        [] -> 0
    end.

%% ---------------------------------------------------------------- signed requests (RF-010-06)

-spec nonce_ok(binary(), binary()) -> ok | replay | unavailable.
nonce_ok(Client, Nonce) ->
    case ana_db:exec("INSERT INTO ana_system.api_nonce (client_id, nonce, expires_at) VALUES ($1, $2, now() + interval '6 minutes') "
                     "ON CONFLICT DO NOTHING", [Client, Nonce]) of
        {ok, 1} -> ok;
        {ok, 0} -> replay;
        _ -> unavailable
    end.

%% HMAC-SHA256 (hex) over method, path, timestamp, nonce and the body's SHA-256; constant time.
-spec signature_ok(map(), binary(), binary(), binary(), binary(), binary(), binary()) -> boolean().
signature_ok(#{signing := Key}, Method, Path, Ts, Nonce, Body, Sig) when is_binary(Key), is_binary(Sig) ->
    Expected = binary:encode_hex(crypto:mac(hmac, sha256, Key, [Method, $\n, Path, $\n, Ts, $\n, Nonce, $\n, sha_hex(Body)]),
                                 lowercase),
    Given = string:lowercase(Sig),
    byte_size(Given) =:= byte_size(Expected) andalso crypto:hash_equals(Given, Expected);
signature_ok(_, _, _, _, _, _, _) -> false.

%% ---------------------------------------------------------------- idempotency (RF-010-07)

-spec idempotency_begin(binary(), binary(), binary()) ->
    new | {replay, integer(), term()} | running | mismatch | unavailable.
idempotency_begin(Client, Key, BodyHash) ->
    case ana_db:exec("INSERT INTO ana_system.api_idempotency (client_id, key, body_hash, status) VALUES ($1, $2, $3, 'running') "
                     "ON CONFLICT (client_id, key) DO UPDATE SET body_hash = EXCLUDED.body_hash, status = 'running', response = NULL, "
                     "  http_status = NULL, created_at = now(), expires_at = now() + interval '24 hours' "
                     "  WHERE ana_system.api_idempotency.expires_at < now()", [Client, Key, BodyHash]) of
        {ok, 1} -> new;
        {ok, 0} ->
            case ana_db:one("SELECT body_hash, status, http_status, response FROM ana_system.api_idempotency "
                            "WHERE client_id = $1 AND key = $2", [Client, Key]) of
                {ok, #{<<"body_hash">> := H}} when H =/= BodyHash -> mismatch;
                {ok, #{<<"status">> := <<"running">>}} -> running;
                {ok, #{<<"status">> := <<"done">>, <<"http_status">> := S, <<"response">> := R}} -> {replay, S, R};
                _ -> unavailable
            end;
        _ -> unavailable
    end.

-spec idempotency_end(binary(), binary(), integer(), term()) -> ok.
idempotency_end(Client, Key, Status, Response) ->
    _ = ana_db:exec("UPDATE ana_system.api_idempotency SET status = 'done', http_status = $3, response = $4 "
                    "WHERE client_id = $1 AND key = $2", [Client, Key, Status, Response]),
    ok.

%% ---------------------------------------------------------------- network rules

-spec public_mode() -> boolean().
public_mode() -> ana_config:text("ANA_PUBLIC_MODE", "false") =:= "true".

%% RNF-010-01: HTTPS directly, or a trusted proxy (ANA_TRUSTED_PROXIES) that says it was HTTPS.
-spec secure(cowboy_req:req()) -> boolean().
secure(Req) ->
    case cowboy_req:scheme(Req) of
        <<"https">> -> true;
        _ ->
            {Peer, _} = cowboy_req:peer(Req),
            Proxies = [C || C <- string:lexemes(ana_config:text("ANA_TRUSTED_PROXIES", ""), ", "), C =/= ""],
            lists:any(fun(C) -> in_cidr(Peer, C) end, Proxies)
                andalso cowboy_req:header(<<"x-forwarded-proto">>, Req) =:= <<"https">>
    end.

-spec ip_allowed(map(), binary()) -> boolean().
ip_allowed(#{<<"ip_allow">> := []}, _) -> true;
ip_allowed(#{<<"ip_allow">> := Cidrs}, Ip) ->
    case inet:parse_address(binary_to_list(Ip)) of
        {ok, Addr} -> lists:any(fun(C) -> in_cidr(Addr, C) end, Cidrs);
        _ -> false
    end;
ip_allowed(_, _) -> true.

in_cidr(Addr, Cidr) ->
    case parse_cidr(Cidr) of
        {Net, Bits} when tuple_size(Net) =:= tuple_size(Addr) ->
            Size = tuple_size(Addr) * (case tuple_size(Addr) of 4 -> 8; _ -> 16 end),
            mask(Addr, Bits, Size) =:= mask(Net, Bits, Size);
        _ -> false
    end.

parse_cidr(C) when is_binary(C) -> parse_cidr(binary_to_list(C));
parse_cidr(C) when is_list(C) ->
    {A, B} = case string:split(C, "/") of [X, Y] -> {X, Y}; [X] -> {X, undefined} end,
    case inet:parse_address(A) of
        {ok, Addr} ->
            Max = case tuple_size(Addr) of 4 -> 32; _ -> 128 end,
            case B of
                undefined -> {Addr, Max};
                _ -> case catch list_to_integer(B) of N when is_integer(N), N >= 0, N =< Max -> {Addr, N}; _ -> error end
            end;
        _ -> error
    end;
parse_cidr(_) -> error.

mask(Addr, Bits, Size) ->
    Unit = case tuple_size(Addr) of 4 -> 8; _ -> 16 end,
    Int = lists:foldl(fun(P, Acc) -> (Acc bsl Unit) bor P end, 0, tuple_to_list(Addr)),
    Int bsr (Size - Bits).

%% ---------------------------------------------------------------- audit (RF-010-11), batched

-spec record(map()) -> ok.
record(Entry) -> ana_bounded:cast(?MODULE, {record, Entry}, 50000).   % spec 062 (D7)

init([]) ->
    _ = ets:new(?CLIENTS, [named_table, public, set, {read_concurrency, true}]),
    _ = ets:new(?META, [named_table, public, set, {read_concurrency, true}]),
    _ = ets:new(?RATE, [named_table, public, set, {write_concurrency, true}]),
    erlang:send_after(1000, self(), flush),
    erlang:send_after(10000, self(), usage),
    erlang:send_after(60000, self(), purge),
    {ok, #{buffer => [], n => 0}}.

handle_call(_, _, S) -> {reply, {error, unknown}, S}.

handle_cast({record, E}, S = #{buffer := B, n := N}) when N >= 1000 -> {noreply, flush_log(S#{buffer := [E | B]})};
handle_cast({record, E}, S = #{buffer := B, n := N}) -> {noreply, S#{buffer := [E | B], n := N + 1}};
handle_cast(_, S) -> {noreply, S}.

handle_info(flush, S) ->
    erlang:send_after(1000, self(), flush),
    {noreply, flush_log(S)};
handle_info(usage, S) ->
    erlang:send_after(10000, self(), usage),
    _ = catch flush_usage(),
    {noreply, S};
handle_info(purge, S) ->
    erlang:send_after(60000, self(), purge),
    _ = catch purge(),
    {noreply, S};
handle_info(_, S) -> {noreply, S}.

flush_log(S = #{buffer := []}) -> S;
flush_log(S = #{buffer := B}) ->
    Col = fun(K) -> [maps:get(K, E, null) || E <- B] end,
    _ = catch ana_db:exec(
        "INSERT INTO ana_system.api_call_log (client_id, username, auth, ip, program, status, duration_ms, idempotency_key) "
        "SELECT * FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::int[], $7::int[], $8::text[])",
        [Col(client), Col(username), Col(auth), Col(ip), Col(program), Col(status), Col(duration_ms), Col(idempotency_key)]),
    S#{buffer := [], n := 0}.

%% Local counts of the day go to the database; the consolidated total (every node) comes back.
flush_usage() ->
    Today = binary:part(list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}])), 0, 10),
    Local = [{Id, N} || {{quota, Id, D}, N} <- ets:tab2list(?RATE), D =:= Today, N > 0],
    _ = [begin
             _ = ets:update_counter(?RATE, {quota, Id, Today}, -N),
             case ana_db:one("INSERT INTO ana_system.api_usage (client_id, day, calls) VALUES ($1, $2::date, $3) "
                             "ON CONFLICT (client_id, day) DO UPDATE SET calls = api_usage.calls + EXCLUDED.calls RETURNING calls",
                             [Id, Today, N]) of
                 {ok, #{<<"calls">> := Total}} -> ets:insert(?RATE, {{quota_db, Id, Today}, Total});
                 _ -> _ = ets:update_counter(?RATE, {quota, Id, Today}, N)   % retried at the next flush
             end
         end || {Id, N} <- Local],
    ok.

purge() ->
    Min = erlang:system_time(second) div 60,
    _ = [ets:select_delete(?RATE, [{{{K, '_', '$1'}, '_'}, [{'<', '$1', Min - 2}], [true]}]) || K <- [rate, calls, fails]],
    NowS = erlang:system_time(second),
    _ = ets:select_delete(?RATE, [{{{tripped, '_'}, '$1'}, [{'=<', '$1', NowS}], [true]}]),
    _ = ana_db:exec("DELETE FROM ana_system.api_nonce WHERE expires_at < now()", []),
    _ = ana_db:exec("DELETE FROM ana_system.api_idempotency WHERE expires_at < now()", []),
    ok.

%% ---------------------------------------------------------------- helpers

b64u(B) -> base64:encode(B, #{mode => urlsafe, padding => false}).
b64d(B) -> base64:decode(B, #{mode => urlsafe, padding => false}).

sha_hex(B) -> binary:encode_hex(crypto:hash(sha256, B), lowercase).

rand_alnum(N) ->
    Chars = <<"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789">>,
    << <<(binary:at(Chars, X rem 62))>> || <<X>> <= crypto:strong_rand_bytes(N) >>.
