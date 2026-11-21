%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Program names (RF-002-01) and access patterns (RF-011-04).
-module(ana_program_tests).
-include_lib("eunit/include/eunit.hrl").

valid_name_test() ->
    ?assert(ana_program:valid_name(<<"sales.create_order">>)),
    ?assert(ana_program:valid_name(<<"demo">>)),
    ?assertNot(ana_program:valid_name(<<"Sales">>)),
    ?assertNot(ana_program:valid_name(<<"a..b">>)),
    ?assertNot(ana_program:valid_name(<<"a.">>)),
    ?assertNot(ana_program:valid_name(<<"a;drop">>)),
    ?assertNot(ana_program:valid_name(<<"../x">>)),
    ?assertNot(ana_program:valid_name(binary:copy(<<"a">>, 129))),
    ?assertNot(ana_program:valid_name(42)).

access_pattern_test() ->
    ?assert(ana_access:matches(<<"projects.*">>, <<"projects.log_time">>)),
    ?assert(ana_access:matches(<<"sales.create_order">>, <<"sales.create_order">>)),
    ?assertNot(ana_access:matches(<<"sales.create_order">>, <<"sales.create_order2">>)),
    ?assertNot(ana_access:matches(<<"projects.*">>, <<"projectsx.a">>)),
    ?assertNot(ana_access:matches(<<"projects.*">>, <<"sales.x">>)).
