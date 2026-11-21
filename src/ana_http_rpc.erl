%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% JSON-RPC 2.0 over HTTP (spec 003: RF-003-01..05, RNF-003-04, RNF-003-05).
-module(ana_http_rpc).
-export([init/2]).

-define(MAX_BATCH, 50).
-define(MAX_PUBLIC_BATCH, 20).

init(Req, functions) ->
    Req2 = ana_http:require(Req, <<"user">>, fun(U) ->
        {ok, Fs} = ana_rpc:functions(maps:remove(api_client, U)),
        ana_http:json(200, Fs, Req)
    end),
    {ok, Req2, functions};
init(Req, rpc) ->
    Req2 = case cowboy_req:method(Req) of
        <<"POST">> ->
            ana_http:require(Req, <<"user">>, fun(U) -> handle(U, Req) end);
        _ ->
            cowboy_req:reply(405, #{<<"allow">> => <<"POST">>}, Req)
    end,
    {ok, Req2, rpc}.

%% Spec 010: public calls — smaller body and batch, signature, limits, idempotency, audit.
handle(#{api_client := C} = U0, Req) ->
    U = maps:remove(api_client, U0),
    case ana_http:read_raw(Req, ana_config:integer("ANA_PUBLIC_MAX_BODY", 262144)) of
        {too_large, R} -> ana_http:reply_error(413, <<"BODY_TOO_LARGE">>, <<"corpo acima do limite da API pública"/utf8>>, R);
        {ok, Body, R} ->
            case signature(C, Body, R) of
                ok ->
                    case catch json:decode(Body) of
                        {'EXIT', _} -> ana_http:json(200, rpc_error(null, -32700, <<"JSON inválido"/utf8>>, null), R);
                        Batch when is_list(Batch), length(Batch) > ?MAX_PUBLIC_BATCH ->
                            ana_http:json(200, rpc_error(null, -32600, <<"lote acima de 20 chamadas">>, null), R);
                        Decoded -> public_calls(U, C, Decoded, Body, R)
                    end;
                {error, Status, Code, Msg} -> ana_http:reply_error(Status, Code, Msg, R)
            end
    end;
handle(U, Req) ->
    case ana_http:read_json(Req) of
        {ok, Batch, R} when is_list(Batch), Batch =/= [], length(Batch) =< ?MAX_BATCH ->
            %% RNF-003-05: batch calls in parallel, each in its own transaction.
            Replies = [X || X <- pmap(fun(Call) -> call(U, Call) end, Batch), X =/= no_reply],
            case Replies of
                [] -> cowboy_req:reply(204, R);
                _ -> ana_http:json(200, Replies, R)
            end;
        {ok, Batch, R} when is_list(Batch) ->
            ana_http:json(200, rpc_error(null, -32600, <<"lote vazio ou acima de 50 chamadas">>, null), R);
        {ok, Call, R} ->
            case call(U, Call) of
                no_reply -> cowboy_req:reply(204, R);
                Reply -> ana_http:json(200, Reply, R)
            end;
        {too_large, R} ->
            ana_http:reply_error(413, <<"BODY_TOO_LARGE">>, <<"corpo da requisição grande demais"/utf8>>, R);
        {invalid, R} ->
            ana_http:json(200, rpc_error(null, -32700, <<"JSON inválido"/utf8>>, null), R)
    end.

call(U, #{<<"jsonrpc">> := <<"2.0">>, <<"method">> := Method} = Call) when is_binary(Method) ->
    Id = maps:get(<<"id">>, Call, no_id),
    Params = maps:get(<<"params">>, Call, #{}),
    Reply = case is_map(Params) of
        false -> rpc_error(Id, -32602, <<"params deve ser um objeto">>, null);
        true ->
            case ana_rpc:call(Method, Params, U) of
                {ok, R} -> #{jsonrpc => <<"2.0">>, id => Id, result => R};
                {error, #{<<"code">> := C} = E} ->
                    rpc_error(Id, ana_rpc:jsonrpc_code(C), maps:get(<<"message">>, E, C),
                              maps:with([<<"code">>, <<"execution_id">>, <<"data">>], E))
            end
    end,
    case Id of
        no_id -> no_reply;    % notification
        _ -> Reply
    end;
call(_, Call) ->
    Id = case Call of #{<<"id">> := I} -> I; _ -> null end,
    rpc_error(Id, -32600, <<"requisição JSON-RPC inválida"/utf8>>, null).

%% RF-010-06: required when the client says so (or whenever the headers come).
signature(C, Body, Req) ->
    Ts = cowboy_req:header(<<"x-ana-timestamp">>, Req),
    Nonce = cowboy_req:header(<<"x-ana-nonce">>, Req),
    Sig = cowboy_req:header(<<"x-ana-signature">>, Req),
    Required = maps:get(<<"require_signature">>, C, false) =:= true,
    case {Required, Sig} of
        {false, undefined} -> ok;
        _ ->
            Fresh = case catch binary_to_integer(Ts) of
                T when is_integer(T) -> abs(erlang:system_time(second) - T) =< 300;
                _ -> false
            end,
            Valid = Fresh andalso is_binary(Nonce) andalso byte_size(Nonce) >= 16 andalso byte_size(Nonce) =< 128
                andalso ana_api:signature_ok(C, cowboy_req:method(Req), cowboy_req:path(Req), Ts, Nonce, Body, Sig),
            case Valid andalso ana_api:nonce_ok(maps:get(<<"client_id">>, C), Nonce) of
                ok -> ok;
                unavailable -> {error, 503, <<"UNAVAILABLE">>, <<"tente de novo"/utf8>>};
                _ -> {error, 401, <<"NOT_AUTHENTICATED">>, <<"credencial ausente ou inválida"/utf8>>}
            end
    end.

public_calls(U, C, Decoded, Body, Req) ->
    Calls = case Decoded of L when is_list(L) -> L; One -> [One] end,
    Ip = ana_http:ip(Req),
    case admit_all(C, Ip, length(Calls)) of
        {error, suspended, After} ->
            cowboy_req:reply(503, #{<<"retry-after">> => integer_to_binary(After), <<"content-type">> => <<"application/json">>},
                             json:encode(#{error => #{code => <<"CLIENT_SUSPENDED">>,
                                                      message => <<"cliente suspenso por excesso de falhas; tente depois"/utf8>>}}), Req);
        {error, rate, After} ->
            cowboy_req:reply(429, #{<<"retry-after">> => integer_to_binary(After), <<"content-type">> => <<"application/json">>},
                             json:encode(#{error => #{code => <<"RATE_LIMITED">>, message => <<"limite de chamadas por minuto"/utf8>>}}), Req);
        {error, quota} ->
            cowboy_req:reply(429, #{<<"retry-after">> => <<"3600">>, <<"content-type">> => <<"application/json">>},
                             json:encode(#{error => #{code => <<"QUOTA_EXCEEDED">>, message => <<"cota diária esgotada"/utf8>>}}), Req);
        {error, overload} ->
            cowboy_req:reply(503, #{<<"retry-after">> => <<"2">>, <<"content-type">> => <<"application/json">>},
                             json:encode(#{error => #{code => <<"OVERLOAD">>, message => <<"capacidade pública esgotada; tente em instantes"/utf8>>}}), Req);
        {ok, N} ->
            try
                case {Decoded, cowboy_req:header(<<"idempotency-key">>, Req)} of
                    {#{}, Key} when is_binary(Key) -> idempotent(U, C, Decoded, Key, Body, Ip, Req);
                    {#{}, _} -> single_reply(audited(U, C, Decoded, Ip, null), Req);
                    {_, _} ->
                        Replies = [X || X <- pmap(fun(Call) -> audited(U, C, Call, Ip, null) end, Calls), X =/= no_reply],
                        case Replies of [] -> cowboy_req:reply(204, Req); _ -> ana_http:json(200, Replies, Req) end
                end
            after
                [ana_api:release() || _ <- lists:seq(1, N)]
            end
    end.

admit_all(C, Ip, N) -> admit_all(C, Ip, N, 0).
admit_all(_, _, 0, Done) -> {ok, Done};
admit_all(C, Ip, N, Done) ->
    case ana_api:admit(C, Ip) of
        ok -> admit_all(C, Ip, N - 1, Done + 1);
        E -> [ana_api:release() || _ <- lists:seq(1, Done)], E
    end.

single_reply(no_reply, Req) -> cowboy_req:reply(204, Req);
single_reply(Reply, Req) -> ana_http:json(200, Reply, Req).

%% RF-010-07 / RNF-010-09: a repeated key never runs twice; in doubt, 503.
idempotent(U, C, Call, Key, Body, Ip, Req) ->
    Client = maps:get(<<"client_id">>, C),
    Hash = binary:encode_hex(crypto:hash(sha256, Body), lowercase),
    case wait_running(ana_api:idempotency_begin(Client, Key, Hash), Client, Key, Hash, 300) of
        new ->
            Reply = audited(U, C, Call, Ip, Key),
            Stored = case Reply of no_reply -> null; _ -> Reply end,
            ok = ana_api:idempotency_end(Client, Key, 200, Stored),
            single_reply(Reply, Req);
        {replay, _Status, null} -> cowboy_req:reply(204, #{<<"idempotent-replayed">> => <<"true">>}, Req);
        {replay, Status, Stored} ->
            cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json; charset=utf-8">>,
                                       <<"idempotent-replayed">> => <<"true">>}, json:encode(Stored), Req);
        running -> ana_http:reply_error(409, <<"IDEMPOTENCY_IN_PROGRESS">>, <<"chamada com esta chave em andamento"/utf8>>, Req);
        mismatch -> ana_http:reply_error(422, <<"IDEMPOTENCY_MISMATCH">>, <<"chave já usada com outro conteúdo"/utf8>>, Req);
        unavailable -> ana_http:reply_error(503, <<"UNAVAILABLE">>, <<"tente de novo"/utf8>>, Req)
    end.

%% The same key arriving while the first call runs waits for its answer (up to 30 s).
wait_running(running, Client, Key, Hash, N) when N > 0 ->
    timer:sleep(100),
    wait_running(ana_api:idempotency_begin(Client, Key, Hash), Client, Key, Hash, N - 1);
wait_running(R, _, _, _, _) -> R.

audited(U = #{username := Who}, C, Call, Ip, Key) ->
    T0 = erlang:monotonic_time(millisecond),
    Reply = call(U, Call),
    ok = ana_api:outcome(maps:get(<<"client_id">>, C), failed(Reply)),
    Status = case Reply of
        #{error := #{code := Code}} when Code =:= -32601; Code =:= -32602; Code =:= -32600 -> 400;
        #{error := #{code := -32603}} -> 500;
        #{error := _} -> 422;
        _ -> 200
    end,
    ana_api:record(#{client => maps:get(<<"client_id">>, C), username => Who, auth => maps:get(auth, maps:get(trace, U)),
                     ip => Ip, program => case Call of #{<<"method">> := M} when is_binary(M) -> M; _ -> null end,
                     status => Status, duration_ms => erlang:monotonic_time(millisecond) - T0, idempotency_key => Key}),
    Reply.

%% RNF-010-10: what counts toward the client's circuit breaker.
failed(#{error := #{code := -32603}}) -> true;
failed(#{error := #{data := #{<<"code">> := Code}}}) -> ana_api:technical(Code);
failed(_) -> false.

rpc_error(Id, Code, Msg, Data) ->
    E = #{code => Code, message => Msg},
    #{jsonrpc => <<"2.0">>, id => Id, error => case Data of null -> E; _ -> E#{data => Data} end}.

pmap(F, L) ->
    Parent = self(),
    Refs = [begin
                Ref = make_ref(),
                {Pid, Mon} = spawn_monitor(fun() -> Parent ! {Ref, F(E)} end),
                {Ref, Pid, Mon}
            end || E <- L],
    [receive
         {Ref, R} -> demonitor(Mon, [flush]), R;
         {'DOWN', Mon, process, Pid, _} -> rpc_error(null, -32603, <<"erro interno">>, null)
     end || {Ref, Pid, Mon} <- Refs].
