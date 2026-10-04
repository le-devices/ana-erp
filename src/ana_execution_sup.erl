%% Execution supervisor: one temporary child per execution (P3).
-module(ana_execution_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => simple_one_for_one, intensity => 1000, period => 1},
          [#{id => ana_execution,
             start => {ana_execution, start_link, []},
             restart => temporary,
             shutdown => 5000}]}}.
