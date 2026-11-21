%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Spec 063 (T-063-01..03): the pure parts of the disk-endurance measure.
-module(ana_disk_tests).
-include_lib("eunit/include/eunit.hrl").

write_table_test_() ->
    [?_assertEqual(<<"sales.sales_order">>, ana_disk:write_table(<<"INSERT INTO sales.sales_order (a) VALUES ($1)">>)),
     ?_assertEqual(<<"base.party">>, ana_disk:write_table(<<"  update base.party SET name = $1 WHERE id = $2">>)),
     ?_assertEqual(<<"t.x">>, ana_disk:write_table(<<"DELETE FROM \"t\".\"x\" WHERE true">>)),
     ?_assertEqual(<<"stock">>, ana_disk:write_table(<<"WITH a AS (SELECT 1) INSERT INTO stock SELECT * FROM a">>)),
     ?_assertEqual(<<"base.party">>, ana_disk:write_table(<<"UPDATE ONLY base.party SET x = 1">>)),
     ?_assertEqual(none, ana_disk:write_table(<<"SELECT * FROM base.party">>)),
     ?_assertEqual(none, ana_disk:write_table(<<"WITH a AS (SELECT 1) SELECT * FROM a">>))].

projection_test_() ->
    PerDay = 10.0e9,                                     % 10 GB a day
    [?_assertEqual(#{informed => false}, ana_disk:projection(0, 0, PerDay)),
     ?_assertMatch(#{informed := true, years_left := 164.4}, ana_disk:projection(600, 0, PerDay)),
     ?_assertMatch(#{years_left := 82.2}, ana_disk:projection(600, 50, PerDay)),
     ?_assertMatch(#{years_left := null}, ana_disk:projection(600, 0, 0)),
     ?_assertMatch(#{left_bytes := 0}, ana_disk:projection(600, 120, PerDay))].

note_writes_test() ->
    catch ets:delete(ana_disk_writes),
    _ = ets:new(ana_disk_writes, [named_table, public, set]),
    ok = ana_disk:note_writes(<<"p.a">>, [{<<"h1">>, <<"UPDATE t.x SET a = 1">>, 2, 0, 0, 5},
                                          {<<"h2">>, <<"SELECT 1">>, 1, 0, 0, 1},
                                          {<<"h1">>, <<"UPDATE t.x SET a = 1">>, 1, 0, 0, 3}]),
    ?assertEqual([{{w, <<"p.a">>, <<"t.x">>}, 8}], ets:lookup(ana_disk_writes, {w, <<"p.a">>, <<"t.x">>})),
    ets:delete(ana_disk_writes).

%% Finding (d): the advice about forced checkpoints looks at the last days, not at the counters
%% accumulated since the statistics were reset.
checkpoint_advice_test_() ->
    Ck = fun(T, R) -> #{<<"recent_timed">> => T, <<"recent_req">> => R, <<"log_temp_files">> => <<"10MB">>,
                        <<"wal_compression">> => <<"lz4">>, <<"archive_mode">> => <<"off">>, <<"archive_timeout">> => <<"0">>} end,
    Forced = fun(S) -> lists:any(fun(X) -> binary:match(X, <<"max_wal_size">>) =/= nomatch end, S) end,
    [?_assert(Forced(ana_disk:suggestions(Ck(5, 40)))),
     ?_assertNot(Forced(ana_disk:suggestions(Ck(600, 16)))),
     ?_assertNot(Forced(ana_disk:suggestions(Ck(3, 8))))].
