%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Type conversion tests (spec 001, T-001-04).
-module(ana_types_tests).
-include_lib("eunit/include/eunit.hrl").

coerce_integers_test() ->
    ?assertEqual(5, ana_types:coerce(int4, 5)),
    ?assertEqual(5, ana_types:coerce(int8, <<"5">>)),
    ?assertEqual(5, ana_types:coerce(int4, 5.0)),
    ?assertThrow({type, int4, 5.5}, ana_types:coerce(int4, 5.5)),
    ?assertThrow({type, int4, <<"x">>}, ana_types:coerce(int4, <<"x">>)).

coerce_dates_test() ->
    ?assertEqual({2026, 10, 2}, ana_types:coerce(date, <<"2026-10-02">>)),
    ?assertThrow({type, date, _}, ana_types:coerce(date, <<"2026-02-30">>)),
    ?assertEqual({{2026, 10, 2}, {12, 30, 0.0}}, ana_types:coerce(timestamp, <<"2026-10-02T12:30:00">>)),
    ?assertEqual({{2026, 10, 2}, {15, 30, 0.0}}, ana_types:coerce(timestamptz, <<"2026-10-02T12:30:00-03:00">>)),
    ?assertEqual({{2026, 10, 2}, {12, 30, 0.0}}, ana_types:coerce(timestamp, <<"2026-10-02 12:30:00-03:00">>)),
    ?assertEqual({{2026, 10, 2}, {0, 0, 0.0}}, ana_types:coerce(timestamp, <<"2026-10-02">>)).

coerce_json_numeric_test() ->
    ?assertEqual(<<"{\"a\":1}">>, ana_types:coerce(jsonb, #{<<"a">> => 1})),
    ?assertEqual(<<"12.50">>, ana_types:coerce({unknown_oid, 1700}, <<"12.50">>)),
    ?assertEqual(null, ana_types:coerce(int4, null)),
    ?assertEqual([1, 2], ana_types:coerce({array, int4}, [<<"1">>, 2])).

coerce_params_count_test() ->
    ?assertMatch({error, _}, ana_types:coerce_params([int4], [])),
    ?assertMatch({error, _}, ana_types:coerce_params([int4], [#{}])),
    ?assertEqual({ok, [1, <<"a">>]}, ana_types:coerce_params([int4, text], [1, <<"a">>])).

to_json_test() ->
    ?assertEqual(<<"2026-10-02">>, ana_types:to_json({2026, 10, 2}, date)),
    ?assertEqual(<<"2026-10-02T01:02:03.500000Z">>, ana_types:to_json({{2026, 10, 2}, {1, 2, 3.5}}, timestamptz)),
    ?assertEqual(<<"2026-10-02T01:02:03">>, ana_types:to_json({{2026, 10, 2}, {1, 2, 3}}, timestamp)),
    ?assertEqual(#{<<"a">> => 1}, ana_types:to_json(<<"{\"a\":1}">>, jsonb)),
    ?assertEqual(<<"AAE=">>, ana_types:to_json(<<0, 1>>, bytea)),
    ?assertEqual(<<"1.50">>, ana_types:to_json(<<"1.50">>, {unknown_oid, 1700})),
    ?assertEqual(<<"numeric">>, ana_types:type_name({unknown_oid, 1700})).
