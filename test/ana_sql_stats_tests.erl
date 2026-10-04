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
