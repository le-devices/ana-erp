%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Spec 068 (T-068-03, D4, RNF-068-04): reading the history from a point without losing a row committed late and
%% without delivering a row twice.
-module(ana_watch_log_tests).
-include_lib("eunit/include/eunit.hrl").

st(High, Missing) -> #{high => High, missing => Missing}.

in_order_test() ->
    ?assertEqual({[11, 12, 13], 13, 13, #{}}, ana_watch_log:advance(st(10, #{}), [11, 12, 13], 0, 900000, 500)).

nothing_new_test() ->
    ?assertEqual({[], 10, 10, #{}}, ana_watch_log:advance(st(10, #{}), [], 0, 900000, 500)).

%% 12 is still in a longer transaction: 11 and 13 go now, the point stays at 11 until 12 comes.
late_commit_is_delivered_once_test() ->
    {D1, P1, H1, M1} = ana_watch_log:advance(st(10, #{}), [11, 13], 1000, 900000, 500),
    ?assertEqual({[11, 13], 11, 13, #{12 => 1000}}, {D1, P1, H1, M1}),
    {D2, P2, H2, M2} = ana_watch_log:advance(st(H1, M1), [12, 14], 2000, 900000, 500),
    ?assertEqual({[12, 14], 14, 14, #{}}, {D2, P2, H2, M2}).

%% A rolled-back id never comes: forgotten after the limit, and the point moves on.
rolled_back_id_is_forgotten_test() ->
    {_, P1, H1, M1} = ana_watch_log:advance(st(10, #{}), [11, 13], 0, 900000, 500),
    ?assertEqual(11, P1),
    {D2, P2, _, M2} = ana_watch_log:advance(st(H1, M1), [], 900000, 900000, 500),
    ?assertEqual({[], 13, #{}}, {D2, P2, M2}).

several_holes_test() ->
    {D, P, H, M} = ana_watch_log:advance(st(10, #{}), [12, 15], 5, 900000, 500),
    ?assertEqual({[12, 15], 10, 15, #{11 => 5, 13 => 5, 14 => 5}}, {D, P, H, M}).
