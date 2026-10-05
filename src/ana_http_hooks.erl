%% Inbound webhooks (spec 017, RF-017-04, RNF-017-02).
%%
%% POST /hooks/<connector>, no session: the HMAC-SHA256 signature of
%% "<timestamp>.<body>" with the connector's hmac_key secret authenticates the
%% sender; the timestamp must be inside the replay window; the event id (header or
%% the JSON field "id") makes delivery idempotent. The event is stored in the inbox
%% and answered 202 at once; the connector's program processes it afterwards.
-module(ana_http_hooks).
-export([init/2, signature/3]).

-define(MAX_BODY, 1024 * 1024).

init(Req, State) ->
    Req2 = try handle(cowboy_req:method(Req), cowboy_req:binding(connector, Req), Req)
           catch C:R:St ->
               logger:error("webhook error: ~0p:~0p ~0p", [C, R, St]),
               ana_http:reply_error(500, <<"INTERNAL">>, <<"erro interno">>, Req)
           end,
    {ok, Req2, State}.

handle(<<"POST">>, Name, Req) when is_binary(Name) ->
    case ana_db:one("SELECT name, signature_header, timestamp_header, event_id_header, replay_window_s "
                    "FROM integration.connector WHERE name = $1 AND kind = 'webhook_in' AND active", [Name]) of
        {ok, #{} = C} -> receive_event(C, Req);
        _ -> ana_http:reply_error(404, <<"NOT_FOUND">>, <<"não encontrado"/utf8>>, Req)
    end;
handle(_, _, Req) ->
    ana_http:reply_error(405, <<"METHOD_NOT_ALLOWED">>, <<"use POST"/utf8>>, Req).

receive_event(C = #{<<"name">> := Name}, Req) ->
    case cowboy_req:body_length(Req) of
        N when is_integer(N), N > ?MAX_BODY -> too_large(Req);
        _ ->
            case cowboy_req:read_body(Req, #{length => ?MAX_BODY, period => 10000}) of
                {more, _, Req2} -> too_large(Req2);
                {ok, Body, Req2} ->
                    case verify(C, Body, Req2) of
                        ok -> store(C, Body, Req2);
                        {error, Why} ->
                            logger:warning("webhook ~ts refused: ~ts (ip ~ts)", [Name, Why, ana_http:ip(Req2)]),
                            ana_http:reply_error(401, <<"INVALID_SIGNATURE">>, <<"assinatura inválida"/utf8>>, Req2)
                    end
            end
    end.

too_large(Req) ->
    ana_http:reply_error(413, <<"BODY_TOO_LARGE">>, <<"corpo grande demais"/utf8>>, Req).

verify(#{<<"name">> := Name, <<"signature_header">> := SH, <<"timestamp_header">> := TH,
         <<"replay_window_s">> := Window}, Body, Req) ->
    Sig = cowboy_req:header(string:lowercase(SH), Req, <<>>),
    Ts = cowboy_req:header(string:lowercase(TH), Req, <<>>),
    Now = erlang:system_time(second),
    case {ana_vault:fetch(Name, <<"hmac_key">>), catch binary_to_integer(Ts)} of
        {{error, _}, _} -> {error, <<"conector sem hmac_key no cofre"/utf8>>};
        {_, T} when not is_integer(T) -> {error, <<"sem carimbo de tempo"/utf8>>};
        {_, T} when abs(Now - T) > Window -> {error, <<"fora da janela anti-repetição"/utf8>>};
        {{ok, Key}, _} ->
            Expected = signature(Key, Ts, Body),
            Given = case Sig of <<"sha256=", Hex/binary>> -> Hex; Hex -> Hex end,
            case byte_size(Given) =:= byte_size(Expected) andalso crypto:hash_equals(Given, Expected) of
                true -> ok;
                false -> {error, <<"assinatura não confere"/utf8>>}
            end
    end.

%% Hex HMAC-SHA256 of "<timestamp>.<body>" (documented for senders and tests).
-spec signature(binary(), binary(), binary()) -> binary().
signature(Key, Ts, Body) ->
    binary:encode_hex(crypto:mac(hmac, sha256, Key, <<Ts/binary, ".", Body/binary>>), lowercase).

store(#{<<"name">> := Name, <<"event_id_header">> := EH}, Body, Req) ->
    Payload = try json:decode(Body) catch _:_ -> #{<<"raw">> => Body} end,
    EventId = case cowboy_req:header(string:lowercase(EH), Req) of
        undefined -> case Payload of #{<<"id">> := I} when is_binary(I); is_integer(I) -> to_bin(I); _ -> undefined end;
        H -> H
    end,
    case EventId of
        undefined ->
            ana_http:reply_error(400, <<"EVENT_ID_REQUIRED">>, <<"evento sem identificador"/utf8>>, Req);
        _ ->
            %% Only harmless headers are kept (never authorization, cookies or the signature).
            Keep = maps:with([<<"content-type">>, <<"user-agent">>, string:lowercase(EH)], cowboy_req:headers(Req)),
            {ok, Rows} = ana_db:rows(
                "INSERT INTO integration.inbox (connector, event_id, payload, headers) VALUES ($1, $2, $3, $4) "
                "ON CONFLICT (connector, event_id) DO NOTHING RETURNING id", [Name, EventId, Payload, Keep]),
            case Rows of
                [#{<<"id">> := Id}] ->
                    ana_integration:poke(),
                    ana_http:json(202, #{received => true, id => Id}, Req);
                [] ->
                    ana_http:json(200, #{received => true, duplicate => true}, Req)
            end
    end.

to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(B) -> binary:part(B, 0, min(200, byte_size(B))).
