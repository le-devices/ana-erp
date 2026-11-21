%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Spec 028: the pure decision behind product update offers.
-module(ana_product_updates_tests).
-include_lib("eunit/include/eunit.hrl").

-define(D(C, B, S, O), ana_product_updates:decide(C, B, S, O)).

in_sync_test() ->
    ?assertEqual(in_sync, ?D(<<"s">>, <<"old">>, <<"s">>, undefined)),
    ?assertEqual(in_sync, ?D(<<"s">>, null, <<"s">>, {<<"available">>, <<"s">>})).

customized_on_current_seed_is_not_offered_test() ->            % CA-028-04
    ?assertEqual(customized, ?D(<<"mine">>, <<"s">>, <<"s">>, undefined)).

new_seed_over_unmodified_program_test() ->                     % CA-028-01
    ?assertEqual({offer, false}, ?D(<<"b">>, <<"b">>, <<"s2">>, undefined)).

new_seed_over_modified_program_test() ->                       % CA-028-02
    ?assertEqual({offer, true}, ?D(<<"mine">>, <<"b">>, <<"s2">>, undefined)),
    ?assertEqual({offer, true}, ?D(<<"mine">>, null, <<"s2">>, undefined)).   % unknown base = modified

dismissed_stays_quiet_until_the_seed_changes_test() ->         % CA-028-03
    ?assertEqual(keep, ?D(<<"b">>, <<"b">>, <<"s2">>, {<<"dismissed">>, <<"s2">>})),
    ?assertEqual({offer, false}, ?D(<<"b">>, <<"b">>, <<"s3">>, {<<"dismissed">>, <<"s2">>})).

hash_matches_postgres_sha256_hex_test() ->
    %% encode(sha256(convert_to('ação', 'UTF8')), 'hex') in PostgreSQL
    ?assertEqual(64, byte_size(ana_product_updates:hash(<<"ação"/utf8>>))),
    ?assertEqual(<<"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855">>,
                 ana_product_updates:hash(<<>>)).
