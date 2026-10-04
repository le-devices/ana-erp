%% JSON-RPC 2.0 over HTTP (spec 003: RF-003-01..05, RNF-003-04, RNF-003-05).
-module(ana_http_rpc).
-export([init/2]).

-define(MAX_BATCH, 50).

init(Req, functions) ->
    Req2 = ana_http:require(Req, <<"user">>, fun(U) ->
        {ok, Fs} = ana_rpc:functions(U),
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
