%% One delivery worker per connector (spec 062, D4): started on demand by ana_integration, stopped when idle.
-module(ana_connector_sup).
-behaviour(supervisor).
-export([start_link/0, start_worker/1, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_worker(Connector) -> supervisor:start_child(?MODULE, [Connector]).

init([]) ->
    {ok, {#{strategy => simple_one_for_one, intensity => 20, period => 60},
          [#{id => worker, start => {ana_connector_worker, start_link, []}, restart => temporary}]}}.
