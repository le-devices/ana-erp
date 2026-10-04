-module(ana_breaker_tests).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    catch ets:delete(ana_breakers),
    ok = ana_breaker:init_table(),
    os:putenv("ANA_BREAKER_OPEN_MS", "100").

fail() -> {error, #{<<"code">> => <<"REMOTE_FAILED">>}}.

%% RF-023-07
opens_after_threshold_and_fails_fast_test() ->
    setup(),
    Calls = counters:new(1, []),
    F = fun() -> counters:add(Calls, 1, 1), fail() end,
    [ana_breaker:call(k, F) || _ <- lists:seq(1, 5)],
    ?assertEqual(open, ana_breaker:state(k)),
    {error, #{<<"code">> := <<"REMOTE_UNAVAILABLE">>}} = ana_breaker:call(k, F),
    ?assertEqual(5, counters:get(Calls, 1)).            % the 6th call never reached the dependency

half_open_trial_closes_on_success_test() ->
    setup(),
    [ana_breaker:call(k2, fun fail/0) || _ <- lists:seq(1, 5)],
    timer:sleep(150),
    ?assertEqual({ok, 1}, ana_breaker:call(k2, fun() -> {ok, 1} end)),
    ?assertEqual(closed, ana_breaker:state(k2)).

half_open_trial_reopens_on_failure_test() ->
    setup(),
    [ana_breaker:call(k3, fun fail/0) || _ <- lists:seq(1, 5)],
    timer:sleep(150),
    _ = ana_breaker:call(k3, fun fail/0),
    ?assertEqual(open, ana_breaker:state(k3)).

business_errors_do_not_open_test() ->
    setup(),
    IsFailure = fun(#{<<"code">> := C}) -> C =:= <<"REMOTE_FAILED">> end,
    [ana_breaker:call(k4, fun() -> {error, #{<<"code">> => <<"NOT_FOUND">>}} end, IsFailure)
     || _ <- lists:seq(1, 10)],
    ?assertEqual(closed, ana_breaker:state(k4)).

%% RF-023-05
db_hosts_test() ->
    ?assertEqual(["pg1", "pg2"], ana_db:hosts(" pg1 , pg2,")),
    ?assertEqual(["db"], ana_db:hosts("db")).
