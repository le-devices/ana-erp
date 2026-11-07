%% Supervisor of one area of the core (spec 062, D1; constitution P20). Each area has its own restart
%% budget: an area that keeps failing exhausts only its own supervisor, which the root restarts as a
%% whole; the other areas keep serving meanwhile.
-module(ana_area_sup).
-behaviour(supervisor).
-export([start_link/2, init/1, areas/0]).

-define(INTENSITY, 10).
-define(PERIOD_S, 60).

start_link(Name, Children) ->
    supervisor:start_link({local, Name}, ?MODULE, Children).

init(Children) ->
    {ok, {#{strategy => one_for_one, intensity => ?INTENSITY, period => ?PERIOD_S}, Children}}.

%% The areas, in start order (the root uses them; the "Núcleo" screen lists them).
-spec areas() -> [atom()].
areas() -> [ana_base_sup, ana_exec_area_sup, ana_work_sup, ana_observe_sup].
