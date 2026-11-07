%% Spec 062 (CA-062-01): an area that keeps failing exhausts only its own supervisor; the other areas
%% keep their processes (nothing restarts there).
-module(ana_area_sup_tests).
-behaviour(supervisor).
-include_lib("eunit/include/eunit.hrl").
-export([init/1, start_worker/1]).

start_worker(Name) ->
    Pid = spawn_link(fun() -> register(Name, self()), receive stop -> ok end end),
    {ok, Pid}.

init(Areas) -> {ok, {#{strategy => one_for_one, intensity => 5, period => 60}, Areas}}.

area(Name, Worker) ->
    #{id => Name, start => {ana_area_sup, start_link, [Name, [#{id => Worker, start => {?MODULE, start_worker, [Worker]}}]]},
      type => supervisor}.

wait_for(Name) ->
    case whereis(Name) of
        undefined -> timer:sleep(5), wait_for(Name);
        Pid -> Pid
    end.

t_062_01_failing_area_does_not_restart_the_others_test() ->
    process_flag(trap_exit, true),
    {ok, Root} = supervisor:start_link(?MODULE, [area(t_area_a_sup, t_worker_a), area(t_area_b_sup, t_worker_b)]),
    B = wait_for(t_worker_b),
    SupA = whereis(t_area_a_sup),
    %% More failures than the area allows (10 in 60 s): its supervisor gives up and the root restarts it.
    [begin exit(wait_for(t_worker_a), kill), timer:sleep(2) end || _ <- lists:seq(1, 12)],
    timer:sleep(50),
    ?assertNotEqual(SupA, whereis(t_area_a_sup)),
    ?assert(is_pid(wait_for(t_worker_a))),
    ?assertEqual(B, whereis(t_worker_b)),          % the other area never noticed
    unlink(Root),
    exit(Root, shutdown).
