%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Security headers middleware (RNF-001-04, RNF-005-01).
-module(ana_http_security).
-behaviour(cowboy_middleware).
-export([execute/2]).

-define(CSP, <<"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
               "connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; "
               "form-action 'self'; frame-ancestors 'none'">>).

execute(Req0, Env) ->
    %% Spec 077 (D14): every answer says when the installation is not in its normal mode (screens, portal, API).
    Req = case ana_mode:message() of
        null -> Req0;
        M -> cowboy_req:set_resp_header(<<"x-ana-mode">>, uri_string:quote(M), Req0)
    end,
    Req2 = cowboy_req:set_resp_headers(#{
        <<"content-security-policy">> => ?CSP,
        <<"x-content-type-options">> => <<"nosniff">>,
        <<"x-frame-options">> => <<"DENY">>,
        <<"referrer-policy">> => <<"no-referrer">>,
        <<"cross-origin-opener-policy">> => <<"same-origin">>,
        <<"cross-origin-resource-policy">> => <<"same-origin">>,
        <<"permissions-policy">> => <<"camera=(self), microphone=(), geolocation=()">>,
        <<"cache-control">> => <<"no-store">>
    }, Req),
    Req3 = case ana_api:public_mode() of
        true -> cowboy_req:set_resp_header(<<"strict-transport-security">>, <<"max-age=31536000; includeSubDomains">>, Req2);
        false -> Req2
    end,
    cors(cowboy_req:path(Req3), cowboy_req:header(<<"origin">>, Req3), Req3, Env).

%% Spec 010 (RF-010-08): only the public routes, only exact origins of active clients (in memory);
%% a preflight is answered here, without the database or a handler.
cors(Path, Origin, Req, Env) when is_binary(Origin), (Path =:= <<"/rpc">> orelse Path =:= <<"/rpc/functions">>
                                                      orelse Path =:= <<"/oauth/token">>) ->
    case ana_api:origin_allowed(Origin) of
        true ->
            Req2 = cowboy_req:set_resp_headers(#{<<"access-control-allow-origin">> => Origin, <<"vary">> => <<"Origin">>,
                                                 <<"cross-origin-resource-policy">> => <<"cross-origin">>,
                                                 <<"access-control-expose-headers">> => <<"Retry-After, Idempotent-Replayed">>}, Req),
            case cowboy_req:method(Req2) of
                <<"OPTIONS">> ->
                    {stop, cowboy_req:reply(204, #{
                        <<"access-control-allow-methods">> => <<"POST, GET, OPTIONS">>,
                        <<"access-control-allow-headers">> =>
                            <<"Authorization, Content-Type, X-Api-Key, Idempotency-Key, X-Ana-Timestamp, X-Ana-Nonce, X-Ana-Signature">>,
                        <<"access-control-max-age">> => <<"600">>}, Req2)};
                _ -> {ok, Req2, Env}
            end;
        false ->
            case cowboy_req:method(Req) of
                <<"OPTIONS">> -> {stop, cowboy_req:reply(204, Req)};      % no CORS headers: the browser refuses
                _ -> {ok, Req, Env}
            end
    end;
cors(_, _, Req, Env) -> {ok, Req, Env}.
