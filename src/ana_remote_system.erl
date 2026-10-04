%% Outbound calls to exposed programs on registered remote systems (RF-003-08).
%%
%% RNF-003-01: the program only names the remote system; URL and credentials
%% live in ana_system.remote_system, out of reach of Python and of ana_exec.
%% RNF-003-03: per-system timeout; failures become REMOTE_FAILED errors.
-module(ana_remote_system).
-export([init_tables/0, call/3, forget/1]).

-define(TOKENS, ana_remote_tokens).

init_tables() ->
    _ = ets:new(?TOKENS, [named_table, public, set]),
    ok.

forget(Name) ->
    ets:delete(?TOKENS, Name),
    ok.

-spec call(binary(), binary(), map()) -> {ok, term()} | {error, map()}.
call(System, Function, Params) when is_binary(System), is_binary(Function), is_map(Params) ->
    case ana_db:one("SELECT name, url, username, password, timeout_ms FROM ana_system.remote_system "
                    "WHERE name = $1 AND active", [System]) of
        {ok, #{} = S} -> call_system(S, Function, Params, 1);
        _ -> failure(<<"sistema remoto desconhecido ou inativo: ", System/binary>>)
    end;
call(_, _, _) ->
    failure(<<"argumentos inválidos"/utf8>>).

call_system(S = #{<<"name">> := Name, <<"url">> := Url}, Function, Params, Retries) ->
    case token(S) of
        {ok, Token} ->
            Body = json:encode(#{jsonrpc => <<"2.0">>, method => Function, params => Params, id => 1}),
            case post(S, <<Url/binary, "/rpc">>, [{"authorization", "Bearer " ++ binary_to_list(Token)}], Body) of
                {ok, 401, _} when Retries > 0 ->
                    forget(Name),
                    call_system(S, Function, Params, Retries - 1);
                {ok, 200, Resp} ->
                    interpret(Resp);
                {ok, Status, _} ->
                    failure(unicode:characters_to_binary(io_lib:format("sistema remoto respondeu HTTP ~b", [Status])));
                {error, Reason} ->
                    failure(Reason)
            end;
        {error, Reason} ->
            failure(Reason)
    end.

interpret(#{<<"result">> := R}) -> {ok, R};
interpret(#{<<"error">> := #{<<"message">> := Msg} = E}) ->
    Code = case E of
        #{<<"data">> := #{<<"code">> := C}} when is_binary(C) -> C;
        _ -> <<"REMOTE_FAILED">>
    end,
    {error, #{<<"code">> => Code, <<"message">> => Msg}};
interpret(_) -> failure(<<"resposta JSON-RPC inválida"/utf8>>).

token(#{<<"name">> := Name, <<"url">> := Url, <<"username">> := U, <<"password">> := P} = S) ->
    case ets:lookup(?TOKENS, Name) of
        [{_, T}] -> {ok, T};
        [] when is_binary(U), is_binary(P) ->
            case post(S, <<Url/binary, "/api/session">>, [], json:encode(#{username => U, password => P})) of
                {ok, 200, #{<<"token">> := T}} ->
                    ets:insert(?TOKENS, {Name, T}),
                    {ok, T};
                {ok, Status, _} ->
                    {error, unicode:characters_to_binary(
                        io_lib:format("login no sistema remoto falhou (HTTP ~b)", [Status]))};
                {error, _} = E -> E
            end;
        [] -> {error, <<"sistema remoto sem credenciais"/utf8>>}
    end.

post(#{<<"timeout_ms">> := T}, Url, Headers, Body) ->
    Options = [{timeout, T}, {connect_timeout, min(T, 5000)}, {autoredirect, false}, {ssl, tls_options()}],
    Req = {binary_to_list(Url), [{"accept", "application/json"} | Headers],
           "application/json", iolist_to_binary(Body)},
    case httpc:request(post, Req, Options, [{body_format, binary}]) of
        {ok, {{_, Status, _}, _, Resp}} ->
            {ok, Status, try json:decode(Resp) catch _:_ -> #{} end};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("falha de rede: ~0p", [Reason]))}
    end.

%% TLS always verified against the system certificates.
tls_options() ->
    CAs = try public_key:cacerts_get() catch _:_ -> [] end,
    [{verify, verify_peer},
     {cacerts, CAs},
     {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].

failure(Msg) ->
    {error, #{<<"code">> => <<"REMOTE_FAILED">>, <<"message">> => Msg}}.
