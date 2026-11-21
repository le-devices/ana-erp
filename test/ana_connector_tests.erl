%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Spec 017: URL building (no SSRF), webhook signature, backoff and vault round trip.
-module(ana_connector_tests).
-include_lib("eunit/include/eunit.hrl").

-define(C, #{<<"base_url">> => <<"https://api.bank.example/v2">>, <<"allowed_hosts">> => [<<"files.bank.example">>]}).
-define(URL(P), ana_connector:target_url(?C, P, #{})).

relative_path_joins_base_test() ->
    ?assertEqual({ok, <<"https://api.bank.example/v2/charges">>}, ?URL(<<"/charges">>)),
    ?assertEqual({ok, <<"https://api.bank.example/v2/x?a=1">>}, ana_connector:target_url(?C, <<"/x">>, #{<<"a">> => 1})).

absolute_url_only_for_allowed_hosts_test() ->
    ?assertMatch({ok, _}, ?URL(<<"https://files.bank.example/f.ofx">>)),
    ?assertMatch({ok, _}, ?URL(<<"https://API.bank.example/other">>)),
    ?assertMatch({error, _}, ?URL(<<"https://evil.example/x">>)),
    ?assertMatch({error, _}, ?URL(<<"http://files.bank.example/f">>)).          % never plain http

tricks_are_refused_test() ->
    [?assertMatch({error, _}, ?URL(P)) || P <- [<<"//evil.example/x">>, <<"/../admin">>, <<"https://user@files.bank.example/">>,
                                                <<"/x\r\nHost: evil">>, <<"\\\\evil">>, <<"ftp://files.bank.example/">>,
                                                <<"evil.example/x">>]].

webhook_signature_is_hmac_sha256_of_timestamp_dot_body_test() ->
    Expected = binary:encode_hex(crypto:mac(hmac, sha256, <<"k">>, <<"1700000000.{}">>), lowercase),
    ?assertEqual(Expected, ana_http_hooks:signature(<<"k">>, <<"1700000000">>, <<"{}">>)).

backoff_grows_and_is_capped_test() ->
    ?assertEqual([10, 20, 40, 80], [ana_integration:backoff_s(N) || N <- [1, 2, 3, 4]]),
    ?assertEqual(3600, ana_integration:backoff_s(30)).

vault_round_trip_and_binding_test() ->
    MK = crypto:strong_rand_bytes(32),
    persistent_term:put({ana_vault, key}, MK),
    try
        {C, N, T} = ana_vault:encrypt(<<"bank">>, <<"token">>, <<"s3cr3t">>),
        ?assertNotEqual(<<"s3cr3t">>, C),
        ?assertEqual({ok, <<"s3cr3t">>}, ana_vault:decrypt(<<"bank">>, <<"token">>, {C, N, T}, MK)),
        %% Copied to another connector or key, it does not open (authenticated data).
        ?assertEqual(error, ana_vault:decrypt(<<"other">>, <<"token">>, {C, N, T}, MK)),
        ?assertEqual(error, ana_vault:decrypt(<<"bank">>, <<"password">>, {C, N, T}, MK)),
        ?assertEqual(error, ana_vault:decrypt(<<"bank">>, <<"token">>, {C, N, T}, crypto:strong_rand_bytes(32)))
    after
        persistent_term:erase({ana_vault, key})
    end.
