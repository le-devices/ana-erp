%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Spec 068 (RF-068-01, D1, D6): the filters of the "changed" trigger and the choice between one firing per record and
%% one grouped firing.
-module(ana_watch_match_tests).
-include_lib("eunit/include/eunit.hrl").

rule(Fields, Filter) -> #{<<"watch_fields">> => Fields, <<"watch_filter">> => Filter, <<"watch_key">> => null}.
ch(Ref, B, A) -> #{key => <<"7">>, changes => #{Ref => [B, A]}}.

-define(LIMIT, <<"finance.credit_profile.credit_limit">>).
-define(STATUS, <<"sales.sales_order.status">>).

only_the_rules_fields_test() ->
    R = rule([?LIMIT], #{}),
    ?assert(ana_watch_match:item(R, ch(?LIMIT, 1, 2))),
    ?assertNot(ana_watch_match:item(R, ch(<<"base.party.email">>, <<"a">>, <<"b">>))).

from_to_test() ->
    R = rule([?STATUS], #{<<"to">> => <<"CANCELLED">>}),
    ?assert(ana_watch_match:item(R, ch(?STATUS, <<"OPEN">>, <<"CANCELLED">>))),
    ?assertNot(ana_watch_match:item(R, ch(?STATUS, <<"OPEN">>, <<"INVOICED">>))),
    R2 = rule([?STATUS], #{<<"from">> => <<"INVOICED">>, <<"to">> => <<"OPEN">>}),
    ?assert(ana_watch_match:item(R2, ch(?STATUS, <<"INVOICED">>, <<"OPEN">>))),
    ?assertNot(ana_watch_match:item(R2, ch(?STATUS, <<"CANCELLED">>, <<"OPEN">>))).

%% "limite de crédito subir mais de 20%"
variation_and_direction_test() ->
    R = rule([?LIMIT], #{<<"min_change_pct">> => 20, <<"direction">> => <<"up">>}),
    ?assert(ana_watch_match:item(R, ch(?LIMIT, 1000, 1250))),
    ?assertNot(ana_watch_match:item(R, ch(?LIMIT, 1000, 1100))),
    ?assertNot(ana_watch_match:item(R, ch(?LIMIT, 1000, 500))),
    ?assert(ana_watch_match:item(R, ch(?LIMIT, <<"1000.00">>, <<"1300.00">>))),
    ?assert(ana_watch_match:item(R, ch(?LIMIT, 0, 10))).

emptied_and_filled_test() ->
    E = <<"base.party.email">>,
    ?assert(ana_watch_match:item(rule([E], #{<<"became">> => <<"empty">>}), ch(E, <<"a@b">>, null))),
    ?assertNot(ana_watch_match:item(rule([E], #{<<"became">> => <<"empty">>}), ch(E, null, <<"a@b">>))),
    ?assert(ana_watch_match:item(rule([E], #{<<"became">> => <<"filled">>}), ch(E, <<>>, <<"a@b">>))).

one_record_test() ->
    R = (rule([?LIMIT], #{}))#{<<"watch_key">> => <<"7">>},
    ?assert(ana_watch_match:item(R, ch(?LIMIT, 1, 2))),
    ?assertNot(ana_watch_match:item(R#{<<"watch_key">> => <<"8">>}, ch(?LIMIT, 1, 2))),
    ?assert(ana_watch_match:item(R#{<<"watch_key">> => 7}, ch(?LIMIT, 1, 2))).

%% D1: an import is out unless the rule asks for it.
origins_test() ->
    ?assert(ana_watch_match:origin_allowed(null, <<"screen">>)),
    ?assertNot(ana_watch_match:origin_allowed(null, <<"import">>)),
    ?assert(ana_watch_match:origin_allowed([<<"import">>], <<"import">>)),
    ?assertNot(ana_watch_match:origin_allowed([<<"api">>], <<"screen">>)).

%% D6, CA-068-05: an import or a routine is one grouped firing; a person's edit is one per record.
grouping_test() ->
    ?assert(ana_watch_match:grouped(<<"auto">>, <<"import">>, 312, null)),
    ?assert(ana_watch_match:grouped(<<"auto">>, <<"routine">>, 2, null)),
    ?assert(ana_watch_match:grouped(<<"auto">>, <<"screen">>, 21, null)),
    ?assertNot(ana_watch_match:grouped(<<"auto">>, <<"screen">>, 3, null)),
    ?assertNot(ana_watch_match:grouped(<<"record">>, <<"import">>, 312, null)),
    ?assert(ana_watch_match:grouped(<<"grouped">>, <<"screen">>, 1, null)),
    ?assertNot(ana_watch_match:grouped(<<"grouped">>, <<"import">>, 312, <<"7">>)).

filter_check_test() ->
    ?assertEqual(ok, ana_watch_match:check_filter(#{<<"to">> => <<"x">>}, false)),
    ?assertMatch({error, _}, ana_watch_match:check_filter(#{<<"sql">> => <<"1=1">>}, false)),
    ?assertMatch({error, _}, ana_watch_match:check_filter(#{<<"to">> => <<"x">>}, true)),
    ?assertEqual(ok, ana_watch_match:check_filter(#{}, true)),
    ?assertMatch({error, _}, ana_watch_match:check_filter(#{<<"min_change_pct">> => -3}, false)),
    ?assertMatch({error, _}, ana_watch_match:check_filter(#{<<"became">> => <<"x">>}, false)).

%% CA-068-04: "a data de entrega foi adiada" — ISO dates compare in time.
dates_direction_test() ->
    D = <<"sales.sales_order_item.promised_date">>,
    R = rule([D], #{<<"direction">> => <<"up">>}),
    ?assert(ana_watch_match:item(R, ch(D, <<"2031-02-01">>, <<"2031-02-05">>))),
    ?assertNot(ana_watch_match:item(R, ch(D, <<"2031-02-05">>, <<"2031-02-01">>))),
    ?assertNot(ana_watch_match:item(R, ch(D, null, <<"2031-02-01">>))),
    ?assert(ana_watch_match:item(rule([D], #{<<"direction">> => <<"down">>}),
                                 ch(D, <<"2031-02-05T10:00:00">>, <<"2031-02-04T09:00:00">>))).
