%% Spec 019 (T-019-08b): alert conditions and silences.
-module(ana_health_tests).
-include_lib("eunit/include/eunit.hrl").

t_019_08b_health_levels_test() ->
    ?assert(ana_health:holds(health, red, <<"yellow">>)),
    ?assert(ana_health:holds(health, yellow, <<"yellow">>)),
    ?assertNot(ana_health:holds(health, green, <<"yellow">>)),
    ?assert(ana_health:holds(health, red, <<"red">>)),
    ?assertNot(ana_health:holds(health, yellow, <<"red">>)).

t_019_08b_thresholds_test() ->
    ?assert(ana_health:holds(<<">">>, 10, 9.5)),
    ?assertNot(ana_health:holds(<<">">>, 10, 10)),
    ?assert(ana_health:holds(<<">=">>, 10, 10.0)),
    ?assert(ana_health:holds(<<"<">>, 0, 1)),
    ?assert(ana_health:holds(<<"<=">>, 1, 1)),
    ?assertNot(ana_health:holds(<<"!=">>, 1, 2)).

silence(Rule, Target, Node, Starts, Ends) ->
    #{<<"rule_id">> => Rule, <<"target">> => Target, <<"node">> => Node, <<"starts">> => Starts, <<"ends">> => Ends}.

t_019_08b_silences_match_by_filters_and_time_test() ->
    All = silence(null, null, null, 100, 200),
    ?assert(ana_health:silenced([All], 7, <<"memory_mb">>, <<"n1">>, 150)),
    ?assertNot(ana_health:silenced([All], 7, <<"memory_mb">>, <<"n1">>, 200)),   % ended
    ?assertNot(ana_health:silenced([All], 7, <<"memory_mb">>, <<"n1">>, 99)),    % not yet
    Rule = silence(7, null, null, 100, 200),
    ?assert(ana_health:silenced([Rule], 7, <<"database">>, <<"n2">>, 150)),
    ?assertNot(ana_health:silenced([Rule], 8, <<"database">>, <<"n2">>, 150)),
    Narrow = silence(7, <<"database">>, <<"n1">>, 100, 200),
    ?assert(ana_health:silenced([Narrow], 7, <<"database">>, <<"n1">>, 150)),
    ?assertNot(ana_health:silenced([Narrow], 7, <<"database">>, <<"n2">>, 150)),
    ?assertNot(ana_health:silenced([Narrow], 7, <<"python">>, <<"n1">>, 150)),
    ?assertNot(ana_health:silenced([], 7, <<"database">>, <<"n1">>, 150)).
