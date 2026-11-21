%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Spec 039 (RF-039-11, CA-039-03): navigation in a BPM model.
-module(ana_bpm_model_tests).
-include_lib("eunit/include/eunit.hrl").

n(Id, Type) -> #{<<"id">> => Id, <<"type">> => Type, <<"name">> => Id, <<"props">> => #{}}.
e(F, T) -> #{<<"id">> => <<F/binary, "-", T/binary>>, <<"from">> => F, <<"to">> => T}.
e(F, T, Extra) -> maps:merge(e(F, T), Extra).

model() ->
    #{<<"nodes">> => [n(<<"s">>, <<"start">>), n(<<"x">>, <<"gw_xor">>), n(<<"a">>, <<"task_auto">>), n(<<"b">>, <<"task_human">>),
                      n(<<"p">>, <<"gw_and">>), n(<<"j">>, <<"gw_and">>), n(<<"o">>, <<"gw_or">>), n(<<"end">>, <<"end">>)],
      <<"edges">> => [e(<<"s">>, <<"x">>),
                      e(<<"x">>, <<"a">>, #{<<"condition">> => [#{<<"field">> => <<"total">>, <<"op">> => <<">">>, <<"value">> => 5000}]}),
                      e(<<"x">>, <<"b">>, #{<<"default">> => true}),
                      e(<<"a">>, <<"p">>), e(<<"a">>, <<"end">>, #{<<"on">> => <<"error">>}),
                      e(<<"p">>, <<"j">>), e(<<"b">>, <<"j">>),
                      e(<<"o">>, <<"a">>, #{<<"condition">> => [#{<<"field">> => <<"pix">>, <<"op">> => <<"=">>, <<"value">> => true}]}),
                      e(<<"o">>, <<"b">>, #{<<"condition">> => [#{<<"field">> => <<"total">>, <<"op">> => <<">=">>, <<"value">> => 10}]}),
                      e(<<"o">>, <<"end">>, #{<<"default">> => true})]}.

exclusive_test_() ->
    M = model(),
    [?_assertEqual({ok, [<<"a">>]}, ana_bpm_model:next(M, <<"x">>, #{<<"total">> => 9000}, <<"done">>)),
     ?_assertEqual({ok, [<<"b">>]}, ana_bpm_model:next(M, <<"x">>, #{<<"total">> => 10}, <<"done">>)),     % default
     ?_assertEqual({ok, [<<"b">>]}, ana_bpm_model:next(M, <<"x">>, #{}, <<"done">>))].

error_path_test_() ->
    M = model(),
    [?_assertEqual({ok, [<<"end">>]}, ana_bpm_model:next(M, <<"a">>, #{}, <<"error">>)),
     ?_assertEqual({ok, [<<"p">>]}, ana_bpm_model:next(M, <<"a">>, #{}, <<"done">>)),                      % error flow not taken
     ?_assertMatch({error, _}, ana_bpm_model:next(M, <<"b">>, #{}, <<"error">>))].

inclusive_test_() ->
    M = model(),
    [?_assertEqual({ok, [<<"a">>, <<"b">>]}, ana_bpm_model:next(M, <<"o">>, #{<<"pix">> => true, <<"total">> => 20}, <<"done">>)),
     ?_assertEqual({ok, [<<"b">>]}, ana_bpm_model:next(M, <<"o">>, #{<<"total">> => 20}, <<"done">>)),
     ?_assertEqual({ok, [<<"end">>]}, ana_bpm_model:next(M, <<"o">>, #{<<"total">> => 1}, <<"done">>))].

join_and_kinds_test_() ->
    M = model(),
    [?_assert(ana_bpm_model:is_join(M, <<"j">>)),
     ?_assertNot(ana_bpm_model:is_join(M, <<"p">>)),
     ?_assertNot(ana_bpm_model:is_join(M, <<"a">>)),                 % a task with 2 incoming is not a gateway
     ?_assertEqual(<<"approval">>, ana_bpm_model:kind(<<"task_approval">>)),
     ?_assertEqual(undefined, ana_bpm_model:kind(<<"gw_and">>)),
     ?_assertEqual({ok, []}, ana_bpm_model:next(M, <<"b">>, #{}, <<"timeout">>))].

rule_test() ->
    A = [#{<<"var">> => <<"level">>, <<"value">> => <<"alto">>, <<"when">> => [#{<<"field">> => <<"total">>, <<"op">> => <<">">>, <<"value">> => 100}]},
         #{<<"var">> => <<"who">>, <<"value">> => <<"{{customer}}">>}],
    ?assertEqual(#{<<"level">> => <<"alto">>, <<"who">> => <<"ACME">>},
                 ana_bpm_model:rule_assign(A, #{<<"total">> => 500, <<"customer">> => <<"ACME">>})),
    ?assertEqual(#{<<"who">> => <<"ACME">>}, ana_bpm_model:rule_assign(A, #{<<"total">> => 5, <<"customer">> => <<"ACME">>})).
