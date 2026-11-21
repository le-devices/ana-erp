%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Cron and business-day calendar (spec 018, T-018-02, CA-018-04).
-module(ana_cron_tests).
-include_lib("eunit/include/eunit.hrl").

c(E) -> {ok, C} = ana_cron:parse(E), C.

parse_errors_test() ->
    ?assertMatch({error, _}, ana_cron:parse(<<"* * *">>)),
    ?assertMatch({error, _}, ana_cron:parse(<<"60 * * * *">>)),
    ?assertMatch({error, _}, ana_cron:parse(<<"* * * 13 *">>)),
    ?assertMatch({error, _}, ana_cron:parse(<<"5-1 * * * *">>)),
    ?assertMatch({error, _}, ana_cron:parse(<<"x * * * *">>)),
    ?assertMatch({ok, _}, ana_cron:parse(<<"*/15 8-18 * jan-jun mon-fri">>)).

every_minute_test() ->
    ?assertEqual({ok, {{2026, 10, 3}, {10, 1, 0}}},
                 ana_cron:next(c(<<"* * * * *">>), {{2026, 10, 3}, {10, 0, 30}})).

steps_and_ranges_test() ->
    C = c(<<"*/15 9-10 * * *">>),
    ?assertEqual([{{2026, 10, 3}, {9, 0, 0}}, {{2026, 10, 3}, {9, 15, 0}}, {{2026, 10, 3}, {9, 30, 0}}],
                 ana_cron:next_n(C, {{2026, 10, 3}, {8, 59, 0}}, 3)),
    ?assertEqual({ok, {{2026, 10, 4}, {9, 0, 0}}}, ana_cron:next(C, {{2026, 10, 3}, {10, 45, 0}})).

day_of_week_test() ->
    %% 2026-10-03 is a Saturday; next weekday 06:00 is Monday 2026-10-05.
    ?assertEqual({ok, {{2026, 10, 5}, {6, 0, 0}}}, ana_cron:next(c(<<"0 6 * * mon-fri">>), {{2026, 10, 3}, {12, 0, 0}})),
    ?assertEqual({ok, {{2026, 10, 4}, {0, 0, 0}}}, ana_cron:next(c(<<"0 0 * * 7">>), {{2026, 10, 3}, {12, 0, 0}})).

dom_or_dow_test() ->
    %% Day 15 OR Monday: from Saturday 3rd, Monday 5th comes first.
    ?assertEqual({ok, {{2026, 10, 5}, {0, 0, 0}}}, ana_cron:next(c(<<"0 0 15 * mon">>), {{2026, 10, 3}, {0, 0, 0}})).

month_rollover_test() ->
    ?assertEqual({ok, {{2027, 1, 1}, {0, 0, 0}}}, ana_cron:next(c(<<"0 0 1 1 *">>), {{2026, 10, 3}, {0, 0, 0}})),
    ?assertEqual({ok, {{2028, 2, 29}, {12, 0, 0}}}, ana_cron:next(c(<<"0 12 29 2 *">>), {{2026, 3, 1}, {0, 0, 0}})).

impossible_test() ->
    ?assertEqual(none, ana_cron:next(c(<<"0 0 31 2 *">>), {{2026, 1, 1}, {0, 0, 0}})).

business_day_test() ->
    ?assert(ana_cron:business_day({2026, 10, 2}, [])),            % Friday
    ?assertNot(ana_cron:business_day({2026, 10, 3}, [])),         % Saturday
    ?assertNot(ana_cron:business_day({2026, 10, 12}, [{2026, 10, 12}])).

ca_018_04_last_business_day_with_holiday_test() ->
    %% April 2026: 30th is Thursday; if it is a holiday, the 29th is the answer.
    ?assertEqual({2026, 4, 30}, ana_cron:last_business_day(2026, 4, [])),
    ?assertEqual({2026, 4, 29}, ana_cron:last_business_day(2026, 4, [{2026, 4, 30}])),
    %% October 2026 ends on Saturday 31 → Friday 30.
    ?assertEqual({2026, 10, 30}, ana_cron:last_business_day(2026, 10, [])).

nth_business_day_test() ->
    ?assertEqual({2026, 10, 5}, ana_cron:nth_business_day(2026, 10, 3, [])),
    ?assertEqual(none, ana_cron:nth_business_day(2026, 10, 30, [])).

next_calendar_test() ->
    ?assertEqual({ok, {{2026, 10, 30}, {18, 0, 0}}},
                 ana_cron:next_calendar(last_business_day, undefined, {18, 0}, {{2026, 10, 3}, {0, 0, 0}}, [])),
    ?assertEqual({ok, {{2026, 11, 30}, {18, 0, 0}}},
                 ana_cron:next_calendar(last_business_day, undefined, {18, 0}, {{2026, 10, 30}, {18, 0, 0}}, [])),
    ?assertEqual({ok, {{2026, 11, 3}, {7, 0, 0}}},
                 ana_cron:next_calendar(nth_business_day, 2, {7, 0}, {{2026, 10, 3}, {0, 0, 0}}, [])).

next_business_test() ->
    %% Every day at 08:00 but business days only: Saturday → Monday.
    ?assertEqual({ok, {{2026, 10, 5}, {8, 0, 0}}},
                 ana_cron:next_business(c(<<"0 8 * * *">>), {{2026, 10, 2}, {9, 0, 0}}, [])).
