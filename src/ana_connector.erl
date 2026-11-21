%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Outbound HTTP through connectors (spec 017, RF-017-03, RNF-017-01).
%%
%% Programs name a connector and a path; the core builds the URL from the
%% connector's base_url (a path never carries scheme or host: no SSRF), checks the
%% host against allowed_hosts, authenticates with secrets from the vault, applies
%% timeout, per-minute rate limit and circuit breaker, verifies TLS and logs each
%% call (without secrets).
-module(ana_connector).
-export([init_tables/0, http/5, lookup/1, target_url/3, rate_ok/1]).

-define(TOKENS, ana_connector_tokens).
-define(RATE, ana_connector_rate).
-define(MAX_BODY, 10 * 1024 * 1024).
-define(METHODS, [<<"GET">>, <<"POST">>, <<"PUT">>, <<"PATCH">>, <<"DELETE">>]).
%% Headers a program may never set: credentials and transport belong to the core.
-define(RESERVED, [<<"authorization">>, <<"host">>, <<"cookie">>, <<"proxy-authorization">>,
                   <<"content-length">>, <<"transfer-encoding">>, <<"connection">>]).

init_tables() ->
    _ = ets:new(?TOKENS, [named_table, public, set]),
    _ = ets:new(?RATE, [named_table, public, set, {write_concurrency, true}]),
    ok.

lookup(Name) ->
    ana_db:one("SELECT name, kind, base_url, auth, api_key_header, token_url, allowed_hosts, timeout_ms, rate_per_min, "
               "active FROM integration.connector WHERE name = $1", [Name]).

%% Opts: json | body (+ content type header), headers (map), params (query map).
-spec http(binary(), binary(), binary(), map(), binary() | null) -> {ok, map()} | {error, map()}.
http(Name, Method0, Path, Opts, ExecId) when is_binary(Name), is_binary(Method0), is_binary(Path), is_map(Opts) ->
    Method = string:uppercase(Method0),
    %% Spec 034 (RF-034-07): a test instance with copied data calls nothing outside.
    Blocked = ana_settings:get(outbound_blocked) =:= 1,
    case Blocked orelse lookup(Name) of
        true -> fail(<<"OUTBOUND_BLOCKED">>, <<"chamadas externas bloqueadas nesta instância (dados copiados da produção)"/utf8>>);
        {ok, #{<<"active">> := true, <<"kind">> := <<"http_api">>} = C} ->
            case {lists:member(Method, ?METHODS), target_url(C, Path, maps:get(<<"params">>, Opts, #{}))} of
                {false, _} -> fail(<<"INVALID_METHOD">>, <<"método HTTP não permitido: "/utf8, Method/binary>>);
                {true, {error, Msg}} -> fail(<<"HOST_NOT_ALLOWED">>, Msg);
                {true, {ok, Url}} ->
                    case rate_ok(C) of
                        false -> fail(<<"RATE_LIMITED">>, <<"limite de chamadas por minuto do conector atingido"/utf8>>);
                        true ->
                            T0 = erlang:monotonic_time(millisecond),
                            R = ana_breaker:call({connector, Name}, fun() -> breaker_view(do_call(C, Method, Url, Opts, 1)) end,
                                                 fun(#{<<"code">> := Code}) ->
                                                         lists:member(Code, [<<"HTTP_SERVER_ERROR">>, <<"CONNECTOR_FAILED">>]);
                                                    (_) -> true end),
                            Result = from_breaker(R),
                            log_call(Name, Method, Path, Result, erlang:monotonic_time(millisecond) - T0, ExecId),
                            Result
                    end
            end;
        {ok, #{}} -> fail(<<"CONNECTOR_INACTIVE">>, <<"conector inativo ou não é de saída HTTP: "/utf8, Name/binary>>);
        _ -> fail(<<"CONNECTOR_NOT_FOUND">>, <<"conector desconhecido: "/utf8, Name/binary>>)
    end;
http(_, _, _, _, _) ->
    fail(<<"INVALID_PARAMETER">>, <<"conector, método e caminho são obrigatórios"/utf8>>).

%% A relative path joins base_url; an absolute https URL is accepted only for an
%% allowed host. Never userinfo, never "..", never a protocol-relative "//host".
-spec target_url(map(), binary(), map()) -> {ok, binary()} | {error, binary()}.
target_url(#{<<"base_url">> := Base, <<"allowed_hosts">> := Allowed}, Path, Params) ->
    BaseHost = host_of(Base),
    Query = case maps:size(Params) of
        0 -> <<>>;
        _ -> iolist_to_binary(["?", uri_string:compose_query([{to_bin(K), to_bin(V)} || {K, V} <- maps:to_list(Params)])])
    end,
    Bad = binary:match(Path, [<<"..">>, <<"\\">>, <<"@">>, <<"\r">>, <<"\n">>, <<" ">>]) =/= nomatch,
    if
        Bad -> {error, <<"caminho inválido"/utf8>>};
        Path =:= <<>> -> {ok, <<Base/binary, Query/binary>>};
        binary_part(Path, 0, 1) =:= <<"/">>, byte_size(Path) > 1, binary_part(Path, 0, 2) =:= <<"//">> ->
            {error, <<"caminho inválido"/utf8>>};
        binary_part(Path, 0, 1) =:= <<"/">> ->
            {ok, <<(string:trim(Base, trailing, "/"))/binary, Path/binary, Query/binary>>};
        true ->
            case uri_string:parse(Path) of
                #{scheme := <<"https">>, host := H} = U when not is_map_key(userinfo, U) ->
                    case lists:member(string:lowercase(H), [BaseHost | [string:lowercase(A) || A <- Allowed]]) of
                        true -> {ok, <<Path/binary, Query/binary>>};
                        false -> {error, <<"host fora da lista do conector: "/utf8, H/binary>>}
                    end;
                _ -> {error, <<"use um caminho relativo (/…) ou uma URL https de host permitido"/utf8>>}
            end
    end.

host_of(Url) ->
    case uri_string:parse(Url) of
        #{host := H} -> string:lowercase(H);
        _ -> <<>>
    end.

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_integer(V) -> integer_to_binary(V);
to_bin(V) when is_float(V) -> float_to_binary(V, [short]);
to_bin(V) when is_atom(V) -> atom_to_binary(V);
to_bin(V) -> iolist_to_binary(json:encode(V)).

rate_ok(#{<<"name">> := Name, <<"rate_per_min">> := Max}) ->
    Minute = erlang:system_time(second) div 60,
    N = ets:update_counter(?RATE, {Name, Minute}, 1, {{Name, Minute}, 0}),
    _ = N =:= 1 andalso ets:select_delete(?RATE, [{{{Name, '$1'}, '_'}, [{'<', '$1', Minute}], [true]}]) >= 0,
    N =< Max.

do_call(C = #{<<"name">> := Name, <<"timeout_ms">> := T}, Method, Url, Opts, Retries) ->
    case auth_headers(C) of
        {error, Msg} -> fail(<<"CONNECTOR_AUTH">>, Msg);
        {ok, AuthH} ->
            User = [{string:lowercase(to_bin(K)), to_bin(V)} || {K, V} <- maps:to_list(maps:get(<<"headers">>, Opts, #{}))],
            Reserved = [string:lowercase(maps:get(<<"api_key_header">>, C)) | ?RESERVED],
            Clean = [{K, V} || {K, V} <- User, not lists:member(K, Reserved), valid_header(K, V)],
            {CT, Body} = case Opts of
                #{<<"json">> := J} -> {<<"application/json">>, iolist_to_binary(json:encode(J))};
                #{<<"body">> := B} when is_binary(B) -> {proplists:get_value(<<"content-type">>, Clean, <<"text/plain">>), B};
                _ -> {undefined, undefined}
            end,
            Headers = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- AuthH ++ Clean, K =/= <<"content-type">>],
            Req = case Body of
                undefined -> {binary_to_list(Url), Headers};
                _ -> {binary_to_list(Url), Headers, binary_to_list(CT), Body}
            end,
            HttpOpts = [{timeout, T}, {connect_timeout, min(T, 5000)}, {autoredirect, false}, {ssl, tls_options()}],
            case httpc:request(method_atom(Method), Req, HttpOpts, [{body_format, binary}]) of
                {ok, {{_, 401, _}, _, _}} when Retries > 0, map_get(<<"auth">>, C) =:= <<"oauth2_client">> ->
                    ets:delete(?TOKENS, Name),
                    do_call(C, Method, Url, Opts, Retries - 1);
                {ok, {{_, _, _}, _, RespBody}} when byte_size(RespBody) > ?MAX_BODY ->
                    fail(<<"RESPONSE_TOO_LARGE">>, <<"resposta acima de 10 MB"/utf8>>);
                {ok, {{_, Status, _}, RespHeaders, RespBody}} ->
                    {ok, response(Status, RespHeaders, RespBody)};
                {error, Reason} ->
                    fail(<<"CONNECTOR_FAILED">>, unicode:characters_to_binary(io_lib:format("falha de rede: ~0p", [Reason])))
            end
    end.

valid_header(K, V) ->
    re:run(K, "^[a-z0-9-]{1,64}$", [{capture, none}]) =:= match andalso
        binary:match(V, [<<"\r">>, <<"\n">>]) =:= nomatch andalso byte_size(V) =< 4096.

method_atom(<<"GET">>) -> get;
method_atom(<<"POST">>) -> post;
method_atom(<<"PUT">>) -> put;
method_atom(<<"PATCH">>) -> patch;
method_atom(<<"DELETE">>) -> delete.

response(Status, RespHeaders, Body) ->
    H = maps:from_list([{string:lowercase(list_to_binary(K)), unicode:characters_to_binary(V)}
                        || {K, V} <- RespHeaders, string:lowercase(K) =/= "set-cookie"]),
    Base = #{<<"status">> => Status, <<"headers">> => H},
    IsJson = binary:match(maps:get(<<"content-type">>, H, <<>>), <<"json">>) =/= nomatch,
    case IsJson andalso (catch json:decode(Body)) of
        false -> Base#{<<"text">> => text(Body)};
        {'EXIT', _} -> Base#{<<"text">> => text(Body)};
        Decoded -> Base#{<<"json">> => Decoded}
    end.

text(Body) ->
    case unicode:characters_to_binary(Body) of
        B when is_binary(B) -> B;
        _ -> base64:encode(Body)
    end.

%% 5xx counts as a failure for the circuit breaker; any status still reaches the program.
breaker_view({ok, #{<<"status">> := S} = R}) when S >= 500 -> {error, #{<<"code">> => <<"HTTP_SERVER_ERROR">>, response => R}};
breaker_view(Other) -> Other.

from_breaker({error, #{<<"code">> := <<"HTTP_SERVER_ERROR">>, response := R}}) -> {ok, R};
from_breaker({error, #{<<"code">> := <<"REMOTE_UNAVAILABLE">>}}) ->
    fail(<<"CONNECTOR_UNAVAILABLE">>, <<"conector indisponível (falhas seguidas); nova tentativa em instantes"/utf8>>);
from_breaker(R) -> R.

auth_headers(#{<<"auth">> := <<"none">>}) -> {ok, []};
auth_headers(#{<<"name">> := N, <<"auth">> := <<"basic">>}) ->
    with_secrets(N, [<<"username">>, <<"password">>], fun([U, P]) ->
        [{<<"authorization">>, <<"Basic ", (base64:encode(<<U/binary, ":", P/binary>>))/binary>>}] end);
auth_headers(#{<<"name">> := N, <<"auth">> := <<"bearer">>}) ->
    with_secrets(N, [<<"token">>], fun([T]) -> [{<<"authorization">>, <<"Bearer ", T/binary>>}] end);
auth_headers(#{<<"name">> := N, <<"auth">> := <<"api_key">>, <<"api_key_header">> := H}) ->
    with_secrets(N, [<<"api_key">>], fun([K]) -> [{string:lowercase(H), K}] end);
auth_headers(C = #{<<"name">> := N, <<"auth">> := <<"oauth2_client">>}) ->
    Now = erlang:monotonic_time(second),
    case ets:lookup(?TOKENS, N) of
        [{_, Token, Until}] when Now < Until -> {ok, [{<<"authorization">>, <<"Bearer ", Token/binary>>}]};
        _ ->
            case oauth2_token(C) of
                {ok, Token, Expires} ->
                    ets:insert(?TOKENS, {N, Token, Now + max(30, Expires - 30)}),
                    {ok, [{<<"authorization">>, <<"Bearer ", Token/binary>>}]};
                {error, _} = E -> E
            end
    end.

with_secrets(Connector, Keys, Fun) ->
    Values = [ana_vault:fetch(Connector, K) || K <- Keys],
    case [M || {error, M} <- Values] of
        [] -> {ok, Fun([V || {ok, V} <- Values])};
        [M | _] -> {error, M}
    end.

oauth2_token(#{<<"name">> := N, <<"token_url">> := Url, <<"timeout_ms">> := T}) ->
    case with_secrets(N, [<<"client_id">>, <<"client_secret">>], fun(V) -> V end) of
        {error, _} = E -> E;
        {ok, [Id, Secret]} ->
            Form = uri_string:compose_query([{<<"grant_type">>, <<"client_credentials">>},
                                             {<<"client_id">>, Id}, {<<"client_secret">>, Secret}]),
            Req = {binary_to_list(Url), [{"accept", "application/json"}], "application/x-www-form-urlencoded", Form},
            case httpc:request(post, Req, [{timeout, T}, {autoredirect, false}, {ssl, tls_options()}],
                               [{body_format, binary}]) of
                {ok, {{_, 200, _}, _, Body}} ->
                    case catch json:decode(Body) of
                        #{<<"access_token">> := Tok} = J when is_binary(Tok) ->
                            {ok, Tok, case maps:get(<<"expires_in">>, J, 300) of E when is_integer(E) -> E; _ -> 300 end};
                        _ -> {error, <<"resposta de token OAuth2 inválida"/utf8>>}
                    end;
                {ok, {{_, S, _}, _, _}} ->
                    {error, unicode:characters_to_binary(io_lib:format("token OAuth2 recusado (HTTP ~b)", [S]))};
                {error, _} -> {error, <<"falha de rede ao obter o token OAuth2"/utf8>>}
            end
    end.

%% TLS always verified against the system certificates.
tls_options() ->
    CAs = try public_key:cacerts_get() catch _:_ -> [] end,
    [{verify, verify_peer}, {cacerts, CAs},
     {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].

log_call(Name, Method, Path, Result, Ms, ExecId) ->
    {Status, Error} = case Result of
        {ok, #{<<"status">> := S}} -> {S, null};
        {error, #{<<"message">> := M}} -> {null, M}
    end,
    Clean = hd(binary:split(Path, <<"?">>)),               % query strings may carry personal data
    _ = spawn(fun() ->
        catch ana_db:exec("INSERT INTO integration.call_log (connector, method, path, status, ms, error, execution_id) "
                          "VALUES ($1, $2, $3, $4, $5, $6, $7::text::uuid)",
                          [Name, Method, binary:part(Clean, 0, min(500, byte_size(Clean))), Status, Ms, Error, ExecId])
    end),
    ok.

fail(Code, Msg) -> {error, #{<<"code">> => Code, <<"message">> => Msg}}.
