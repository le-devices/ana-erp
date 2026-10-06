%% Root supervisor (spec 001 plan "Árvore de supervisão").
-module(ana_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% Shared tables belong to the supervisor (they live as long as it does).
    ok = ana_execution:init_tables(),
    ok = ana_remote_system:init_tables(),
    ok = ana_settings:init_cache(),
    ok = ana_program:init_cache(),
    ok = ana_access:init_cache(),
    ok = ana_limits:init_cache(),
    ok = ana_breaker:init_table(),
    ok = ana_metrics:init_table(),
    ok = ana_connector:init_tables(),
    Pool = ana_config:integer("ANA_DB_POOL", 10),
    PoolExec = ana_config:integer("ANA_DB_POOL_EXEC", 20),
    Children = [
        worker(ana_security, []),
        #{id => ana_db, start => {ana_db, start_link, [ana_db, fun ana_config:db/0, Pool]}},
        #{id => ana_db_exec,
          start => {ana_db, start_link, [ana_db_exec, fun() -> ana_config:db_role(exec) end, PoolExec]}},
        worker(ana_listener, []),
        worker(ana_py_pool, []),
        #{id => ana_execution_sup, start => {ana_execution_sup, start_link, []}, type => supervisor},
        worker(ana_access_log, []),
        worker(ana_analytics, []),
        worker(ana_scheduler, []),
        worker(ana_retention, []),
        worker(ana_sql_stats, []),
        worker(ana_advisor, []),
        worker(ana_checks, []),
        worker(ana_flows, []),
        worker(ana_health, []),
        worker(ana_integration, [])
    ],
    {ok, {#{strategy => one_for_one, intensity => 10, period => 60}, Children}}.

worker(M, A) ->
    #{id => M, start => {M, start_link, A}}.
