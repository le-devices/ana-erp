%% Users, passwords, sessions and roles (specs 001 and 011).
%%
%% RF-001-03 PBKDF2-SHA256 with random salt          RF-001-09 brute-force lockout
%% RF-001-04 initial admin                           RF-001-10 roles
%% RF-001-05/06/08 opaque session tokens (stored as SHA-256), expiry
%% RF-011-03 password policy and forced change        RF-011-09 login audit
%% RNF-001-06 constant-time comparison
-module(ana_security).
-behaviour(gen_server).

-export([start_link/0, ensure_admin/0,
         hash_password/1, verify_password/2, check_policy/2,
         login/3, logout/1, validate/1, validate_key/2, new_api_key/0, owner/1,
         create_user/5, set_password/3, change_password/3,
         revoke_sessions/1, unlock/1, unlock_ip/1, clear_cache/0,
         level/1, has_role/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(ITERATIONS, 210000).
-define(ATTEMPTS, ana_attempts).
-define(CACHE, ana_session_cache).
-define(CACHE_TTL_MS, 30000).
-define(MAX_FAILURES_IP, 30).
%% Dummy hash to equalize timing when the user does not exist.
-define(DUMMY_HASH, <<"pbkdf2_sha256$210000$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA">>).

%% ==========================================================================
%% Passwords
%% ==========================================================================

-spec hash_password(binary()) -> binary().
hash_password(Password) ->
    Salt = crypto:strong_rand_bytes(16),
    H = crypto:pbkdf2_hmac(sha256, Password, Salt, ?ITERATIONS, 32),
    iolist_to_binary(["pbkdf2_sha256$", integer_to_binary(?ITERATIONS), "$", b64(Salt), "$", b64(H)]).

-spec verify_password(binary(), binary()) -> boolean().
verify_password(Password, Stored) ->
    try binary:split(Stored, <<"$">>, [global]) of
        [<<"pbkdf2_sha256">>, Iter, Salt64, H64] ->
            Expected = d64(H64),
            Calc = crypto:pbkdf2_hmac(sha256, Password, d64(Salt64), binary_to_integer(Iter),
                                      byte_size(Expected)),
            crypto:hash_equals(Calc, Expected);
        _ -> false
    catch _:_ -> false
    end.

%% RF-011-03
-spec check_policy(binary(), binary()) -> ok | {error, binary()}.
check_policy(Username, Password) when is_binary(Password) ->
    Min = ana_settings:get(password_min_length),
    case string:length(Password) of
        N when N < Min ->
            {error, unicode:characters_to_binary(
                io_lib:format("a senha deve ter ao menos ~b caracteres", [Min]))};
        _ when Password =:= Username ->
            {error, <<"a senha não pode ser igual ao login"/utf8>>};
        _ -> ok
    end;
check_policy(_, _) -> {error, <<"senha inválida"/utf8>>}.

b64(B) -> base64:encode(B, #{mode => urlsafe, padding => false}).
d64(B) -> base64:decode(B, #{mode => urlsafe, padding => false}).

%% ==========================================================================
%% Users
%% ==========================================================================

%% RF-001-04
ensure_admin() ->
    case ana_db:one("SELECT count(*) AS n FROM ana_system.app_user", []) of
        {ok, #{<<"n">> := 0}} ->
            Password = list_to_binary(ana_config:text("ANA_ADMIN_PASSWORD", "admin")),
            {ok, _} = create_user(<<"admin">>, <<"Administrador">>, Password, <<"admin">>, false),
            logger:notice("admin user created"),
            ok;
        {ok, _} -> ok
    end.

create_user(Username, Name, Password, Role, MustChange) ->
    ana_db:exec(
        "INSERT INTO ana_system.app_user (username, name, password_hash, role, must_change_password) "
        "VALUES ($1, $2, $3, $4, $5)",
        [Username, Name, hash_password(Password), Role, MustChange]).

%% Admin reset (RF-011-02): also ends every session of the user.
set_password(Username, Password, MustChange) ->
    R = ana_db:exec("UPDATE ana_system.app_user SET password_hash = $2, must_change_password = $3 "
                    "WHERE username = $1", [Username, hash_password(Password), MustChange]),
    _ = revoke_sessions(Username),
    R.

%% Self-service change (RF-011-03); keeps the caller's current session alive.
-spec change_password(map(), binary(), binary()) -> ok | {error, credentials | binary()}.
change_password(#{username := U}, Current, New) ->
    {ok, Rec} = ana_db:one("SELECT password_hash FROM ana_system.app_user WHERE username = $1", [U]),
    Hash = case Rec of undefined -> ?DUMMY_HASH; #{<<"password_hash">> := H} -> H end,
    case verify_password(Current, Hash) andalso Rec =/= undefined of
        false -> {error, credentials};
        true when Current =:= New -> {error, <<"a nova senha deve ser diferente da atual"/utf8>>};
        true ->
            case check_policy(U, New) of
                ok ->
                    {ok, 1} = ana_db:exec(
                        "UPDATE ana_system.app_user SET password_hash = $2, must_change_password = false "
                        "WHERE username = $1", [U, hash_password(New)]),
                    clear_cache(),
                    ok;
                E -> E
            end
    end.

revoke_sessions(Username) ->
    R = ana_db:exec("DELETE FROM ana_system.session WHERE username = $1", [Username]),
    clear_cache(),
    R.

%% Clears the failed-attempt counter of an address (e.g. an office behind one IP).
-spec unlock_ip(binary()) -> ok.
unlock_ip(Ip) ->
    ets:delete(?ATTEMPTS, {ip, Ip}),
    ok.

unlock(Username) ->
    ets:delete(?ATTEMPTS, {login, Username}),
    ok.

clear_cache() ->
    ets:delete_all_objects(?CACHE),
    ok.

%% ==========================================================================
%% Sessions
%% ==========================================================================

%% RF-001-05, RF-001-09, RF-011-09
-spec login(binary(), binary(), binary()) -> {ok, binary(), map()} | {error, credentials | locked}.
login(Username, Password, Ip) ->
    case locked(Username, Ip) of
        true ->
            audit_login(Username, Ip, false, <<"locked">>),
            {error, locked};
        false ->
            {ok, Rec} = ana_db:one(
                "SELECT username, name, password_hash, role, must_change_password, kind "
                "FROM ana_system.app_user WHERE username = $1 AND active", [Username]),
            Hash = case Rec of undefined -> ?DUMMY_HASH; #{<<"password_hash">> := H} -> H end,
            Valid = verify_password(Password, Hash) andalso Rec =/= undefined,
            case Valid andalso maps:get(<<"kind">>, Rec) =:= <<"robot">> of
                true ->
                    %% RF-011-12: robots never log in interactively.
                    audit_login(Username, Ip, false, <<"robot">>),
                    {error, credentials};
                false -> login_checked(Valid, Rec, Username, Ip)
            end
    end.

login_checked(Valid, Rec, Username, Ip) ->
            case Valid of
                true ->
                    clear_failures(Username),
                    Token = b64(crypto:strong_rand_bytes(32)),
                    {ok, 1} = ana_db:exec(
                        "INSERT INTO ana_system.session (token_hash, username, expires_at) "
                        "VALUES ($1, $2, now() + make_interval(hours => $3))",
                        [crypto:hash(sha256, Token), Username, ana_settings:get(session_hours)]),
                    _ = ana_db:exec("UPDATE ana_system.app_user SET last_login_at = now() WHERE username = $1",
                                    [Username]),
                    audit_login(Username, Ip, true, null),
                    {ok, Token, user(Rec)};
                false ->
                    record_failure(Username, Ip),
                    audit_login(Username, Ip, false, <<"credentials">>),
                    {error, credentials}
            end.

logout(Token) ->
    H = crypto:hash(sha256, Token),
    ets:delete(?CACHE, H),
    ana_db:exec("DELETE FROM ana_system.session WHERE token_hash = $1", [H]).

%% RF-001-06, RF-001-08
-spec validate(binary()) -> {ok, map()} | {error, invalid}.
validate(Token) when byte_size(Token) > 20, byte_size(Token) < 100 ->
    H = crypto:hash(sha256, Token),
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?CACHE, H) of
        [{_, User, Until}] when Until > Now -> {ok, User};
        _ ->
            case ana_db:one(
                   "SELECT u.username, u.name, u.role, u.must_change_password, u.kind "
                   "FROM ana_system.session s JOIN ana_system.app_user u USING (username) "
                   "WHERE s.token_hash = $1 AND s.expires_at > now() AND u.active", [H]) of
                {ok, #{} = Rec} ->
                    U = user(Rec),
                    ets:insert(?CACHE, {H, U, Now + ?CACHE_TTL_MS}),
                    {ok, U};
                _ ->
                    {error, invalid}
            end
    end;
validate(_) -> {error, invalid}.

%% P14 / RF-011-16: every execution has an owner — an active user (person or
%% robot). Cached like sessions; deactivation clears the cache.
-spec owner(map()) -> ok | {error, no_owner}.
owner(#{username := U}) when is_binary(U), U =/= <<>> ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?CACHE, {owner, U}) of
        [{_, _, Exp}] when Exp > Now -> ok;
        _ ->
            case ana_db:one("SELECT 1 AS ok FROM ana_system.app_user WHERE username = $1 AND active", [U]) of
                {ok, #{<<"ok">> := 1}} ->
                    ets:insert(?CACHE, {{owner, U}, true, Now + ?CACHE_TTL_MS}),
                    ok;
                _ -> {error, no_owner}
            end
    end;
owner(_) -> {error, no_owner}.

user(#{<<"username">> := U, <<"role">> := R} = Rec) ->
    #{username => U, role => R, name => maps:get(<<"name">>, Rec, <<>>),
      kind => maps:get(<<"kind">>, Rec, <<"human">>),
      must_change_password => maps:get(<<"must_change_password">>, Rec, false)}.

%% RF-011-13/14: robot API keys. The IP check is done by PostgreSQL (`<<=` on
%% cidr), and cached per (key, ip) for 30 s; revocation clears the cache.
-spec validate_key(binary(), binary()) -> {ok, map()} | {error, invalid}.
validate_key(<<"ana_rk_", _/binary>> = Key, Ip) when byte_size(Key) < 120 ->
    H = crypto:hash(sha256, Key),
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?CACHE, {key, H, Ip}) of
        [{_, User, Until}] when Until > Now -> {ok, User};
        _ ->
            case ana_db:one(
                   "SELECT k.id, u.username, u.name, u.role, u.kind FROM ana_system.api_key k "
                   "JOIN ana_system.app_user u USING (username) "
                   "WHERE k.key_hash = $1 AND k.revoked_at IS NULL AND u.active AND u.kind = 'robot' "
                   "  AND (k.expires_at IS NULL OR k.expires_at > now()) "
                   "  AND (cardinality(k.ip_allow) = 0 OR $2::text::inet <<= ANY(k.ip_allow))", [H, Ip]) of
                {ok, #{<<"id">> := Id} = Rec} ->
                    U = (user(Rec))#{key_id => Id},
                    ets:insert(?CACHE, {{key, H, Ip}, U, Now + ?CACHE_TTL_MS}),
                    _ = spawn(fun() -> ana_db:exec("UPDATE ana_system.api_key SET last_used_at = now() "
                                                    "WHERE id = $1 AND (last_used_at IS NULL OR "
                                                    "last_used_at < now() - interval '1 minute')", [Id]) end),
                    {ok, U};
                _ -> {error, invalid}
            end
    end;
validate_key(_, _) -> {error, invalid}.

%% New random key: {Secret, Prefix, Hash}.
new_api_key() ->
    Secret = <<"ana_rk_", (b64(crypto:strong_rand_bytes(32)))/binary>>,
    {Secret, binary:part(Secret, 0, 12), crypto:hash(sha256, Secret)}.

audit_login(Username, Ip, Success, Reason) ->
    _ = ana_db:exec("INSERT INTO ana_system.login_event (username, ip, success, reason) "
                    "VALUES ($1, $2, $3, $4)", [Username, Ip, Success, Reason]),
    ok.

%% ==========================================================================
%% Roles (RF-001-10)
%% ==========================================================================

level(<<"admin">>) -> 3;
level(<<"developer">>) -> 2;
level(<<"user">>) -> 1;
level(_) -> 0.

-spec has_role(map() | binary(), binary()) -> boolean().
has_role(#{role := R}, Min) -> has_role(R, Min);
has_role(R, Min) -> level(R) >= level(Min) andalso level(R) > 0.

%% ==========================================================================
%% Brute force (RF-001-09)
%% ==========================================================================

locked(Username, Ip) ->
    exceeds({login, Username}, ana_settings:get(max_login_failures))
        orelse exceeds({ip, Ip}, ?MAX_FAILURES_IP).

lockout_ms() -> ana_settings:get(lockout_minutes) * 60000.

exceeds(Key, Max) ->
    Now = erlang:monotonic_time(millisecond),
    Window = lockout_ms(),
    case ets:lookup(?ATTEMPTS, Key) of
        [{_, N, Since}] when N >= Max, Now - Since < Window -> true;
        _ -> false
    end.

record_failure(Username, Ip) ->
    Now = erlang:monotonic_time(millisecond),
    _ = [count(K, Now) || K <- [{login, Username}, {ip, Ip}]],
    ok.

count(Key, Now) ->
    Window = lockout_ms(),
    case ets:lookup(?ATTEMPTS, Key) of
        [{_, N, Since}] when Now - Since < Window -> ets:insert(?ATTEMPTS, {Key, N + 1, Now});
        _ -> ets:insert(?ATTEMPTS, {Key, 1, Now})
    end.

clear_failures(Username) ->
    ets:delete(?ATTEMPTS, {login, Username}).

%% ==========================================================================
%% Table owner + periodic cleanup
%% ==========================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    _ = ets:new(?ATTEMPTS, [named_table, public, set]),
    _ = ets:new(?CACHE, [named_table, public, set, {read_concurrency, true}]),
    erlang:send_after(60000, self(), cleanup),
    {ok, #{}}.

handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(cleanup, S) ->
    Now = erlang:monotonic_time(millisecond),
    _ = ets:select_delete(?ATTEMPTS, [{{'_', '_', '$1'}, [{'<', '$1', Now - lockout_ms()}], [true]}]),
    _ = ets:select_delete(?CACHE, [{{'_', '_', '$1'}, [{'<', '$1', Now}], [true]}]),
    _ = ana_db:exec("DELETE FROM ana_system.session WHERE expires_at < now()", []),
    erlang:send_after(60000, self(), cleanup),
    {noreply, S};
handle_info(_, S) -> {noreply, S}.
