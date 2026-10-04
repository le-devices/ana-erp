%% Read side of observability (spec 019): what the studio screens show.
-module(ana_observability).
-export([health/0, sql_top/1, sql_detail/1, samples/1, program_performance/1, trace/1]).

%% RF-019-01: current state per component, open incidents and recent changes.
health() ->
    States = ana_health:state(),
    {ok, Incidents} = ana_health:incidents(false),
    {ok, Events} = ana_health:history(72),
    {ok, #{components => [S#{component => C} || {C, S} <- lists:sort(maps:to_list(States))],
           incidents => Incidents, events => Events}}.

%% RF-019-07a: statements by total time (or by max), optionally of one program.
sql_top(F) ->
    Order = case maps:get(<<"order">>, F, <<"total">>) of
        <<"max">> -> "max_ms";
        <<"calls">> -> "calls";
        <<"mean">> -> "total_ms / GREATEST(calls, 1)";
        _ -> "total_ms"
    end,
    ana_db:rows(iolist_to_binary(
        ["SELECT hash, sql, calls, total_ms, max_ms, round(total_ms / GREATEST(calls, 1), 3) AS mean_ms, rows, "
         "  slow_calls, programs, first_seen, last_seen, plan_summary, plan_at "
         "FROM ana_system.sql_stat WHERE ($1::text IS NULL OR $1 = ANY(programs)) "
         "ORDER BY ", Order, " DESC LIMIT 100"]),
        [case maps:get(<<"program">>, F, <<>>) of <<>> -> null; P -> P end]).

sql_detail(Hash) ->
    case ana_db:one("SELECT * FROM ana_system.sql_stat WHERE hash = $1", [Hash]) of
        {ok, undefined} -> {error, not_found};
        {ok, R} ->
            {ok, Advice} = ana_db:rows("SELECT id, rule, severity, title, detail, suggestion, status FROM ana_system.advice "
                                       "WHERE target LIKE $1 || '%' OR evidence->>'hash' = $1 ORDER BY last_seen DESC", [Hash]),
            {ok, R#{<<"advice">> => Advice}};
        E -> E
    end.

%% Metric samples for charts (RF-019-02).
samples(Hours) ->
    ana_db:rows("SELECT at, node, metrics FROM ana_system.metric_sample "
                "WHERE at > now() - make_interval(hours => $1) ORDER BY at", [Hours]).

%% Development → program → Desempenho: static findings, its statements, last profile.
program_performance(Name) ->
    case ana_db:one("SELECT name, lint FROM ana_system.program WHERE name = $1", [Name]) of
        {ok, undefined} -> {error, not_found};
        {ok, #{<<"lint">> := Lint}} ->
            {ok, Sql} = sql_top(#{<<"program">> => Name}),
            {ok, Prof} = ana_db:one("SELECT execution_id::text AS execution_id, started_at, sql_ms, profile "
                                    "FROM ana_system.execution_trace WHERE program = $1 AND profile IS NOT NULL "
                                    "ORDER BY started_at DESC LIMIT 1", [Name]),
            {ok, #{lint => case Lint of null -> []; L -> L end, sql => Sql, profile => Prof}};
        E -> E
    end.

trace(Id) ->
    case ana_db:one("SELECT reason, sql_ms, events, profile FROM ana_system.execution_trace "
                    "WHERE execution_id = $1::text::uuid", [Id]) of
        {ok, R} -> R;
        _ -> undefined
    end.
