%% Retention policy (spec 024, RF-024-08..10, RNF-024-02).
%%
%% Once a day, after the configured hour in the client's time zone, one node
%% of the cluster claims the day (ana_system.retention_day) and purges what is
%% past each category's retention. Purges run in small batches with pauses,
%% as an internal task owned by the robot "system" (P14); an administrator
%% can also run one, as its owner.
-module(ana_retention).
-behaviour(gen_server).

-export([start_link/0, purge_now/1, overview/0, categories/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TICK_MS, 60000).
-define(BATCH, 5000).
-define(PAUSE_MS, 50).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% {Key, Label, Setting, Table, TimeColumn, Extra condition}
categories() ->
    [{access, <<"Acessos e comandos SQL"/utf8>>, retention_access_days,
      "ana_system.access_event", "at", "true"},
     {logins, <<"Logins"/utf8>>, retention_login_days,
      "ana_system.login_event", "at", "true"},
     {executions, <<"Execuções (registro)"/utf8>>, retention_execution_days,
      "ana_system.execution", "started_at", "status <> 'running'"},
     {payload, <<"Conteúdo das execuções"/utf8>>, retention_payload_days,
      "ana_system.execution", "started_at", "payload_purged_at IS NULL AND status <> 'running'"},
     {tasks, <<"Tarefas internas"/utf8>>, retention_task_days,
      "ana_system.task_run", "started_at", "status <> 'running'"},
     {scheduler, <<"Ocorrências do agendamento"/utf8>>, retention_scheduler_days,
      "scheduler.occurrence", "scheduled_at", "status NOT IN ('pending', 'running')"},
     {notifications, <<"Avisos do agendamento"/utf8>>, retention_scheduler_days,
      "scheduler.notification", "created_at", "true"},
     {admin_log, <<"Alterações administrativas"/utf8>>, retention_admin_log_days,
      "ana_system.admin_log", "at", "true"},
     %% Spec 019.
     {traces, <<"Rastros de execução e perfis"/utf8>>, retention_trace_days,
      "ana_system.execution_trace", "started_at", "true"},
     {health, <<"Eventos de saúde"/utf8>>, retention_observability_days,
      "ana_system.health_event", "at", "true"},
     {incidents, <<"Incidentes encerrados"/utf8>>, retention_observability_days,
      "ana_system.incident", "opened_at", "closed_at IS NOT NULL"},
     {metrics, <<"Amostras de métricas"/utf8>>, retention_observability_days,
      "ana_system.metric_sample", "at", "true"},
     %% Spec 017: only finished messages; pending and dead ones stay until decided.
     {integration_calls, <<"Chamadas de integração"/utf8>>, retention_integration_days,
      "integration.call_log", "at", "true"},
     {integration_outbox, <<"Mensagens de saída entregues"/utf8>>, retention_integration_days,
      "integration.outbox", "created_at", "status IN ('done', 'discarded')"},
     {integration_inbox, <<"Mensagens de entrada processadas"/utf8>>, retention_integration_days,
      "integration.inbox", "received_at", "status IN ('done', 'discarded')"}].

%% Manual purge (RF-024-09): owned by the administrator who asked.
-spec purge_now(map()) -> {ok, binary()} | {error, term()}.
purge_now(Owner) ->
    gen_server:call(?MODULE, {purge, Owner, <<"studio">>}, 600000).

%% RF-024-10
-spec overview() -> {ok, map()}.
overview() ->
    Cats = [category_overview(C) || C <- categories()],
    {ok, Last} = ana_db:rows(
        "SELECT username, origin, started_at, finished_at, status, detail FROM ana_system.task_run "
        "WHERE task = 'retention.purge' ORDER BY started_at DESC LIMIT 5", []),
    {ok, #{categories => Cats, last_purges => Last, hour => ana_settings:get(retention_hour)}}.

category_overview({Key, Label, Setting, Table, Col, Cond}) ->
    Days = ana_settings:get(Setting),
    {ok, Stats} = ana_db:one(
        "SELECT COALESCE(sum(GREATEST(c.reltuples, 0)), 0)::bigint AS rows, "
        "       COALESCE(sum(pg_total_relation_size(c.oid)), 0)::bigint AS bytes "
        "FROM pg_class c WHERE c.oid = $1::text::regclass "
        "   OR c.oid IN (SELECT relid FROM pg_partition_tree($1::text::regclass))",
        [list_to_binary(Table)]),
    %% Never analyzed (small/new tables): bounded exact count.
    Rows = case maps:get(<<"rows">>, Stats, 0) of
        0 ->
            {ok, #{<<"n">> := N}} = ana_db:one(iolist_to_binary(
                ["SELECT count(*) AS n FROM (SELECT 1 FROM ", Table, " WHERE ", Cond, " LIMIT 1000000) x"]), []),
            N;
        R -> R
    end,
    {ok, Old} = ana_db:one(iolist_to_binary(
        ["SELECT ", Col, " AS oldest, (SELECT count(*) FROM (SELECT 1 FROM ", Table,
         " WHERE ", Col, " < now() - make_interval(days => $1) AND ", Cond,
         " LIMIT 100000) x) AS expired FROM ", Table, " WHERE ", Cond, " ORDER BY ", Col, " LIMIT 1"]), [Days]),
    #{key => Key, label => Label, setting => Setting, days => Days,
      rows => Rows, bytes => maps:get(<<"bytes">>, Stats, 0),
      oldest => case Old of #{<<"oldest">> := O} -> O; _ -> null end,
      expired => case Old of #{<<"expired">> := E} -> E; _ -> 0 end}.

%% ---------------------------------------------------------------- server

init([]) ->
    self() ! partitions,
    erlang:send_after(?TICK_MS, self(), tick),
    {ok, #{running => undefined, waiting => []}}.

handle_call({purge, Owner, Origin}, From, S = #{running := undefined}) ->
    {noreply, start(Owner, Origin, S#{waiting := [From]})};
handle_call({purge, _, _}, From, S = #{waiting := W}) ->
    %% Already purging: answer when the current run finishes.
    {noreply, S#{waiting := [From | W]}}.

handle_cast(_, S) -> {noreply, S}.

handle_info(tick, S) ->
    erlang:send_after(?TICK_MS, self(), tick),
    S2 = case S of
        #{running := undefined} ->
            case catch claim_today() of
                true -> start(ana_task:system_user(), <<"internal">>, S);
                _ -> S
            end;
        _ -> S
    end,
    {noreply, S2};
handle_info(partitions, S) ->
    _ = (catch ensure_partitions()),
    _ = (catch ana_parallel:recover(periodic)),         % spec 022: old orphan prepared transactions
    _ = (catch ana_ha:interrupted(periodic)),           % spec 023: executions of nodes that did not return
    erlang:send_after(3600000, self(), partitions),
    {noreply, S};
handle_info({purge_done, Pid, Result}, S = #{running := {Pid, Mon}, waiting := W}) ->
    erlang:demonitor(Mon, [flush]),
    _ = [gen_server:reply(F, Result) || F <- W],
    {noreply, S#{running := undefined, waiting := []}};
handle_info({'DOWN', Mon, process, _, Reason}, S = #{running := {_, Mon}, waiting := W}) ->
    _ = [gen_server:reply(F, {error, Reason}) || F <- W],
    {noreply, S#{running := undefined, waiting := []}};
handle_info(_, S) ->
    {noreply, S}.

%% The purge runs in its own process: a failure never takes this server down.
start(Owner, Origin, S) ->
    Parent = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        R = ana_task:run(<<"retention.purge">>, Owner, Origin, fun() -> purge() end),
        Parent ! {purge_done, self(), R}
    end),
    S#{running := {Pid, Mon}}.

%% RF-024-09: after the configured hour, the first node to claim the day runs it.
claim_today() ->
    Tz = list_to_binary(ana_config:timezone()),
    {ok, #{<<"h">> := H}} = ana_db:one("SELECT extract(hour FROM now() AT TIME ZONE $1)::int AS h", [Tz]),
    H >= ana_settings:get(retention_hour) andalso
        case ana_db:one("INSERT INTO ana_system.retention_day (day, node) "
                        "VALUES ((now() AT TIME ZONE $1)::date, $2) ON CONFLICT DO NOTHING RETURNING day",
                        [Tz, ana_config:node_id()]) of
            {ok, #{<<"day">> := _}} -> true;
            _ -> false
        end.

purge() ->
    Counts = maps:from_list([{K, purge_category(C)} || C = {K, _, _, _, _, _} <- categories()]),
    _ = ana_db:exec("DELETE FROM ana_system.retention_day WHERE day < current_date - 400", []),
    {ok, iolist_to_binary(json:encode(Counts))}.

%% RF-025-02: whole partitions past the cutoff are dropped; only the default
%% partition is purged row by row.
purge_category({access, _, Setting, _, _, _}) ->
    Days = ana_settings:get(Setting),
    {ok, Old} = ana_db:rows(
        "SELECT name FROM (SELECT c.relname AS name, "
        "  (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \\(''([^'']+)''\\)'))[1]::timestamptz AS upper "
        "  FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid "
        "  WHERE i.inhparent = 'ana_system.access_event'::regclass "
        "    AND c.relname <> 'access_event_default') p "
        "WHERE upper <= now() - make_interval(days => $1)", [Days]),
    Dropped = lists:sum([drop_partition(N) || #{<<"name">> := N} <- Old]),
    Dropped + batches(<<"DELETE FROM ana_system.access_event_default WHERE ctid = ANY(ARRAY("
                       "SELECT ctid FROM ana_system.access_event_default "
                       "WHERE at < now() - make_interval(days => $1) LIMIT $2))">>, Days, 0);
purge_category({payload, _, Setting, Table, Col, Cond}) ->
    batches(iolist_to_binary(["UPDATE ", Table, " SET params = NULL, result = NULL, output = NULL, "
             "  error = CASE WHEN error IS NULL THEN NULL ELSE error - 'trace' END, "
             "  internal_trace = NULL, payload_purged_at = now() "
             "WHERE ctid = ANY(ARRAY(SELECT ctid FROM ", Table, " WHERE ", Col,
             " < now() - make_interval(days => $1) AND ", Cond, " LIMIT $2))"]),
            ana_settings:get(Setting), 0);
purge_category({_, _, Setting, Table, Col, Cond}) ->
    batches(iolist_to_binary(["DELETE FROM ", Table, " WHERE ctid = ANY(ARRAY(SELECT ctid FROM ", Table,
                              " WHERE ", Col, " < now() - make_interval(days => $1) AND ", Cond, " LIMIT $2))"]),
            ana_settings:get(Setting), 0).

drop_partition(Name) ->
    {ok, #{<<"n">> := N}} = ana_db:one(
        iolist_to_binary(["SELECT count(*) AS n FROM ana_system.", quote(Name)]), []),
    case ana_db:exec(iolist_to_binary(["DROP TABLE ana_system.", quote(Name)]), []) of
        {ok, _} -> N;
        {error, E} -> logger:warning("could not drop partition ~ts: ~0p", [Name, E]), 0
    end.

%% Daily partitions from yesterday to +7 days (RF-025-02), in UTC.
ensure_partitions() ->
    Today = erlang:system_time(second) div 86400,
    [ensure_partition(D) || D <- lists:seq(Today - 1, Today + 7)],
    ok.

ensure_partition(Day) ->
    {{Y, M, D}, _} = calendar:gregorian_seconds_to_datetime(Day * 86400 + 62167219200),
    {{Y2, M2, D2}, _} = calendar:gregorian_seconds_to_datetime((Day + 1) * 86400 + 62167219200),
    Name = io_lib:format("access_event_~4..0b~2..0b~2..0b", [Y, M, D]),
    Sql = io_lib:format("CREATE TABLE IF NOT EXISTS ana_system.~s PARTITION OF ana_system.access_event "
                        "FOR VALUES FROM ('~4..0b-~2..0b-~2..0b 00:00:00+00') TO ('~4..0b-~2..0b-~2..0b 00:00:00+00')",
                        [Name, Y, M, D, Y2, M2, D2]),
    case ana_db:exec(iolist_to_binary(Sql), []) of
        {ok, _} -> ok;
        {error, E} -> logger:warning("could not create partition ~s: ~0p", [Name, E])
    end.

quote(Name) ->
    <<"access_event_", Digits/binary>> = Name,
    true = lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Digits)),
    Name.

%% RNF-024-02: small batches with a pause, until nothing is left.
batches(Sql, Days, Total) ->
    case ana_db:exec(Sql, [Days, ?BATCH]) of
        {ok, N} when is_integer(N), N >= ?BATCH ->
            timer:sleep(?PAUSE_MS),
            batches(Sql, Days, Total + N);
        {ok, N} when is_integer(N) -> Total + N;
        {error, E} ->
            logger:warning("retention purge failed on ~ts: ~0p", [Sql, E]),
            Total
    end.
