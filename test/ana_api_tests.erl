%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Spec 010: pure parts of the public API.
-module(ana_api_tests).
-include_lib("eunit/include/eunit.hrl").

scope_test_() ->
    S = fun ana_api:in_scope/2,
    [?_assert(S([<<"sales.create_order">>], <<"sales.create_order">>)),
     ?_assert(S([<<"sales.*">>], <<"sales.create_order">>)),
     ?_assertNot(S([<<"sales.*">>], <<"salesx.create">>)),            % prefix of a module, not of a word
     ?_assertNot(S([<<"sales.*">>], <<"finance.post_entry">>)),
     ?_assertNot(S([], <<"sales.create_order">>)),                     % a new client has no scope (RNF-010-07)
     ?_assertNot(S([<<"*">>], <<"sales.create_order">>))].

ip_test_() ->
    A = fun(Cidrs, Ip) -> ana_api:ip_allowed(#{<<"ip_allow">> => Cidrs}, Ip) end,
    [?_assert(A([], <<"203.0.113.9">>)),
     ?_assert(A([<<"203.0.113.0/24">>], <<"203.0.113.9">>)),
     ?_assertNot(A([<<"203.0.113.0/24">>], <<"203.0.114.9">>)),
     ?_assert(A([<<"10.0.0.7/32">>, <<"2001:db8::/32">>], <<"2001:db8::1">>)),
     ?_assertNot(A([<<"10.0.0.7/32">>], <<"lixo">>))].

%% CA-010-06: the signature covers method, path, timestamp, nonce and the body.
signature_test() ->
    K = crypto:strong_rand_bytes(32),
    Body = <<"{\"jsonrpc\":\"2.0\"}">>,
    Sig = binary:encode_hex(crypto:mac(hmac, sha256, K, [<<"POST">>, $\n, <<"/rpc">>, $\n, <<"1800000000">>, $\n,
                                                         <<"nonce-0123456789ab">>, $\n,
                                                         binary:encode_hex(crypto:hash(sha256, Body), lowercase)]), lowercase),
    C = #{signing => K},
    ?assert(ana_api:signature_ok(C, <<"POST">>, <<"/rpc">>, <<"1800000000">>, <<"nonce-0123456789ab">>, Body, Sig)),
    ?assertNot(ana_api:signature_ok(C, <<"POST">>, <<"/rpc">>, <<"1800000000">>, <<"nonce-0123456789ab">>, <<Body/binary, " ">>, Sig)),
    ?assertNot(ana_api:signature_ok(C, <<"POST">>, <<"/rpc">>, <<"1800000001">>, <<"nonce-0123456789ab">>, Body, Sig)),
    ?assertNot(ana_api:signature_ok(#{signing => undefined}, <<"POST">>, <<"/rpc">>, <<"1">>, <<"n">>, Body, Sig)).

%% CA-010-10 / RNF-010-01: plain HTTP is only accepted from a declared proxy that says it was HTTPS.
secure_test() ->
    Req = fun(Scheme, Peer, Headers) -> #{scheme => Scheme, peer => {Peer, 40000}, headers => Headers} end,
    os:putenv("ANA_TRUSTED_PROXIES", "10.0.0.0/8"),
    try
        ?assert(ana_api:secure(Req(<<"https">>, {203, 0, 113, 9}, #{}))),
        ?assertNot(ana_api:secure(Req(<<"http">>, {203, 0, 113, 9}, #{}))),
        ?assertNot(ana_api:secure(Req(<<"http">>, {203, 0, 113, 9}, #{<<"x-forwarded-proto">> => <<"https">>}))),
        ?assert(ana_api:secure(Req(<<"http">>, {10, 1, 2, 3}, #{<<"x-forwarded-proto">> => <<"https">>}))),
        ?assertNot(ana_api:secure(Req(<<"http">>, {10, 1, 2, 3}, #{<<"x-forwarded-proto">> => <<"http">>})))
    after
        os:unsetenv("ANA_TRUSTED_PROXIES")
    end.

%% Spec 010 (RNF-010-10): only the platform's or the program's failures open a client's breaker.
t_010_06b_technical_failures_test() ->
    [?assert(ana_api:technical(C)) || C <- [<<"TIMEOUT">>, <<"INTERNAL">>, <<"EXCEPTION">>, <<"MEMORY">>, <<"SQL">>]],
    [?assertNot(ana_api:technical(C)) || C <- [<<"INVALID_PARAMETER">>, <<"FORBIDDEN">>, <<"NOT_FOUND">>,
                                               <<"QUOTA_EXCEEDED">>, <<"ORDER_HELD">>]].
