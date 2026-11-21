%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% OAuth token endpoint (spec 010, RF-010-02): client_credentials → short signed access token.
%% Strict limits per address against guessing (RNF-010-04); generic failures (RNF-010-05).
-module(ana_http_oauth).
-export([init/2]).

-define(PER_IP_MIN, 30).

init(Req, token) ->
    Req2 = case cowboy_req:method(Req) of
        <<"POST">> -> token(Req);
        _ -> cowboy_req:reply(405, #{<<"allow">> => <<"POST">>}, Req)
    end,
    {ok, Req2, token}.

token(Req) ->
    Ip = ana_http:ip(Req),
    case limited(Ip) of
        {true, After} ->
            cowboy_req:reply(429, #{<<"retry-after">> => integer_to_binary(After), <<"content-type">> => <<"application/json">>},
                             json:encode(#{error => <<"slow_down">>}), Req);
        false ->
            case ana_api:public_mode() andalso not ana_api:secure(Req) of
                true -> fail(403, <<"invalid_request">>, Req);
                false ->
                    case read(Req) of
                        {ok, P, R} -> grant(P, basic(R), Ip, R);
                        {error, R} -> fail(400, <<"invalid_request">>, R)
                    end
            end
    end.

grant(#{<<"grant_type">> := <<"client_credentials">>} = P, Basic, Ip, Req) ->
    {Id, Secret} = case Basic of
        {I, S} -> {I, S};
        none -> {maps:get(<<"client_id">>, P, null), maps:get(<<"client_secret">>, P, null)}
    end,
    Requested = case maps:get(<<"scope">>, P, <<>>) of S0 when is_binary(S0) -> string:lexemes(S0, " "); _ -> [] end,
    case ana_api:client(Id) of
        {ok, #{<<"usable">> := true, <<"kind">> := <<"confidential">>} = C} ->
            case ana_api:ip_allowed(C, Ip) andalso ana_api:check_secret(C, Secret) of
                true ->
                    case ana_api:issue(C, Requested) of
                        {ok, T} ->
                            ana_api:record(#{client => Id, username => maps:get(<<"run_as">>, C), auth => <<"oauth_token">>, ip => Ip,
                                             program => <<"oauth/token">>, status => 200, duration_ms => 0, idempotency_key => null}),
                            cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>, <<"cache-control">> => <<"no-store">>,
                                                    <<"pragma">> => <<"no-cache">>}, json:encode(T), Req);
                        {error, _} -> fail(503, <<"temporarily_unavailable">>, Req)
                    end;
                false -> failed(Id, Ip, Req)
            end;
        {error, unavailable} -> fail(503, <<"temporarily_unavailable">>, Req);        % spec 023: try again
        _ -> _ = ana_security:verify_password(<<"x">>, <<"pbkdf2_sha256$210000$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA">>),
             failed(Id, Ip, Req)                           % same time whether the client exists or not
    end;
grant(_, _, _, Req) -> fail(400, <<"unsupported_grant_type">>, Req).

failed(Id, Ip, Req) ->
    ana_api:record(#{client => case is_binary(Id) of true -> Id; false -> null end, username => null, auth => <<"oauth_token">>,
                     ip => Ip, program => <<"oauth/token">>, status => 401, duration_ms => 0, idempotency_key => null}),
    fail(401, <<"invalid_client">>, Req).

fail(Status, Code, Req) ->
    cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>, <<"cache-control">> => <<"no-store">>},
                     json:encode(#{error => Code}), Req).

%% Form (application/x-www-form-urlencoded, as RFC 6749) or JSON.
read(Req) ->
    case ana_http:read_raw(Req, 8192) of
        {ok, Body, R} ->
            case cowboy_req:header(<<"content-type">>, R) of
                <<"application/json", _/binary>> ->
                    case catch json:decode(Body) of M when is_map(M) -> {ok, M, R}; _ -> {error, R} end;
                _ ->
                    %% Form encoding writes spaces as "+".
                    case catch uri_string:dissect_query(binary:replace(Body, <<"+">>, <<"%20">>, [global])) of
                        L when is_list(L) -> {ok, maps:from_list([{K, V} || {K, V} <- L, is_binary(K), is_binary(V)]), R};
                        _ -> {error, R}
                    end
            end;
        {too_large, R} -> {error, R}
    end.

basic(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Basic ", B64/binary>> ->
            case catch base64:decode(string:trim(B64)) of
                Bin when is_binary(Bin) ->
                    case binary:split(Bin, <<":">>) of
                        [I, S] -> {uri_string:percent_decode(I), uri_string:percent_decode(S)};
                        _ -> none
                    end;
                _ -> none
            end;
        _ -> none
    end.

%% Per-address counter in the same table as the client limits (per node).
limited(Ip) ->
    NowS = erlang:system_time(second),
    Min = NowS div 60,
    case ets:update_counter(ana_api_rate, {rate, {oauth_ip, Ip}, Min}, 1, {{rate, {oauth_ip, Ip}, Min}, 0}) of
        N when N > ?PER_IP_MIN -> {true, 60 - (NowS rem 60)};
        _ -> false
    end.
