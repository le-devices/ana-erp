%% Security headers middleware (RNF-001-04, RNF-005-01).
-module(ana_http_security).
-behaviour(cowboy_middleware).
-export([execute/2]).

-define(CSP, <<"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
               "connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; "
               "form-action 'self'; frame-ancestors 'none'">>).

execute(Req, Env) ->
    Req2 = cowboy_req:set_resp_headers(#{
        <<"content-security-policy">> => ?CSP,
        <<"x-content-type-options">> => <<"nosniff">>,
        <<"x-frame-options">> => <<"DENY">>,
        <<"referrer-policy">> => <<"no-referrer">>,
        <<"cross-origin-opener-policy">> => <<"same-origin">>,
        <<"cross-origin-resource-policy">> => <<"same-origin">>,
        <<"permissions-policy">> => <<"camera=(), microphone=(), geolocation=()">>,
        <<"cache-control">> => <<"no-store">>
    }, Req),
    {ok, Req2, Env}.
