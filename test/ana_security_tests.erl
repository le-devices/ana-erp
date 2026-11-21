%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Passwords and roles (spec 001: RF-001-03, RF-001-10, RNF-001-06).
-module(ana_security_tests).
-include_lib("eunit/include/eunit.hrl").

password_test_() ->
    {timeout, 30, fun() ->
        H = ana_security:hash_password(<<"secret">>),
        ?assertMatch(<<"pbkdf2_sha256$210000$", _/binary>>, H),
        ?assert(ana_security:verify_password(<<"secret">>, H)),
        ?assertNot(ana_security:verify_password(<<"other">>, H)),
        ?assertNotEqual(H, ana_security:hash_password(<<"secret">>)),   % random salt
        ?assertNot(ana_security:verify_password(<<"x">>, <<"garbage">>))
    end}.

roles_test() ->
    ?assert(ana_security:has_role(<<"admin">>, <<"developer">>)),
    ?assert(ana_security:has_role(#{role => <<"developer">>}, <<"user">>)),
    ?assertNot(ana_security:has_role(<<"user">>, <<"developer">>)),
    ?assertNot(ana_security:has_role(<<"intruder">>, <<"intruder">>)).
