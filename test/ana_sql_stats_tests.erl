%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
-module(ana_sql_stats_tests).
-include_lib("eunit/include/eunit.hrl").

%% RF-019-07a: statements are grouped by normalized text.
normalize_and_hash_test() ->
    A = ana_sql_stats:normalize(<<"SELECT  id\n  FROM base.party   WHERE id = $1 ">>),
    ?assertEqual(<<"SELECT id FROM base.party WHERE id = $1">>, A),
    ?assertEqual(ana_sql_stats:hash(A), ana_sql_stats:hash(ana_sql_stats:normalize(<<"SELECT id FROM base.party WHERE id = $1">>))),
    ?assertEqual(16, byte_size(ana_sql_stats:hash(A))).

%% RF-019-06: sequential scans and the filtered columns become an index suggestion.
plan_summary_test() ->
    Plan = [#{<<"Plan">> => #{<<"Node Type">> => <<"Sort">>, <<"Total Cost">> => 120.5,
                              <<"Plans">> => [#{<<"Node Type">> => <<"Seq Scan">>, <<"Relation Name">> => <<"x_missing">>,
                                                <<"Schema">> => <<"ana_test">>, <<"Plan Rows">> => 7,
                                                <<"Filter">> => <<"((lower(party.name) ~~ $1) AND (party.city = $2))">>}]}}],
    S = ana_sql_stats:summarize_plan(Plan),
    ?assertEqual(120.5, maps:get(cost, S)),
    ?assertEqual(1, maps:get(sorts, S)),
    [Scan] = maps:get(seq_scans, S),
    ?assertEqual(<<"ana_test.x_missing">>, maps:get(table, Scan)),
    ?assertEqual([<<"city">>, <<"name">>], maps:get(columns, Scan)).

%% RF-019-06 with permission by data (spec 009 D10): the row-security terms the database adds to every
%% statement on base.party are not the statement's filter, so they never reach the index tip.
plan_summary_ignores_row_security_test() ->
    F = <<"((party.city = $1) AND ((NOT base.scope_portfolio()) OR (party.kind = 'supplier'::text) OR "
          "(party.salesperson = current_setting('ana.username'::text, true))))">>,
    Plan = [#{<<"Plan">> => #{<<"Node Type">> => <<"Seq Scan">>, <<"Relation Name">> => <<"party">>,
                              <<"Schema">> => <<"base">>, <<"Plan Rows">> => 100, <<"Filter">> => F}}],
    [Scan] = maps:get(seq_scans, ana_sql_stats:summarize_plan(Plan)),
    ?assertEqual([<<"city">>], maps:get(columns, Scan)),
    %% A quoted ' AND ' inside a literal does not split the filter.
    G = <<"((party.name = 'a AND b'::text) AND (party.city = $1))">>,
    [Scan2] = maps:get(seq_scans, ana_sql_stats:summarize_plan(
        [#{<<"Plan">> => #{<<"Node Type">> => <<"Seq Scan">>, <<"Relation Name">> => <<"party">>, <<"Filter">> => G}}])),
    ?assertEqual([<<"city">>, <<"name">>], maps:get(columns, Scan2)).
