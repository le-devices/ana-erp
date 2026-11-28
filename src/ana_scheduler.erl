%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Scheduler engine (spec 018).
%%
%% One process per node. Only the leader (session advisory lock on a dedicated
%% connection, RNF-018-01) works; if its node dies, the connection closes, the
%% lock is released and another node takes over on its next tick.
%%
%% Each tick (1 s) on the leader:
%%   1. due triggers → pending occurrences (INSERT … ON CONFLICT DO NOTHING:
%%      each (job, scheduled_at, attempt) exists once — exactly-once), applying
%%      the missed-runs policy (RF-018-04);
%%   2. pending occurrences → executions, honoring concurrency and the allowed
%%      window (RF-018-02/03);
%%   3. late warnings (RF-018-08).
%% Each execution runs in a monitored worker that records the result, retries
%% with exponential backoff, notifies, pauses (RF-018-05) and fires dependent
%% jobs (RF-018-06).
-module(ana_scheduler).
-behaviour(gen_server).

-export([start_link/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(LOCK_KEY, 7_741_018).
-define(TICK_MS, 1000).
-define(GRACE_S, 60).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

status() ->
    gen_server:call(?MODULE, status, 5000).

init([]) ->
    process_flag(trap_exit, true),
    erlang:send_after(2000, self(), tick),
    {ok, #{conn => undefined, leader => false, workers => #{}}}.

handle_call(status, _From, S = #{leader := L, workers := W}) ->
    {reply, #{leader => L, node => node_name(), running => maps:size(W)}, S}.

handle_cast(_, S) -> {noreply, S}.

handle_info(tick, S0) ->
    S = ensure_leader(S0),
    S2 = case S of
        #{leader := true} ->
            try work(S)
            catch Class:Reason:Stack ->
                logger:error("scheduler tick failed: ~0p:~0p ~0p", [Class, Reason, Stack]),
                S
            end;
        _ -> S
    end,
    erlang:send_after(?TICK_MS, self(), tick),
    {noreply, S2};
handle_info({'DOWN', _Ref, process, Pid, Reason}, S = #{workers := W}) ->
    case maps:take(Pid, W) of
        {OccId, W2} when Reason =/= normal ->
            logger:error("scheduler worker for occurrence ~b died: ~0p", [OccId, Reason]),
            _ = ana_db:exec("UPDATE scheduler.occurrence SET status = 'error', finished_at = now(), "
                            "error = '{\"code\": \"INTERNAL\", \"message\": \"falha no agendador\"}' "
                            "WHERE id = $1 AND status = 'running'", [OccId]),
            {noreply, S#{workers => W2}};
        {_, W2} -> {noreply, S#{workers => W2}};
        error -> {noreply, S}
    end;
handle_info({'EXIT', C, _}, S = #{conn := C}) ->
    logger:warning("scheduler lost its leadership connection"),
    {noreply, S#{conn => undefined, leader => false}};
handle_info(_, S) ->
    {noreply, S}.

%% ==========================================================================
%% Leadership (RNF-018-01)
%% ==========================================================================

ensure_leader(S = #{leader := true}) -> S;
ensure_leader(S = #{conn := undefined}) ->
    case ana_db:connect((ana_config:db())#{application_name => "ana_scheduler"}) of
        {ok, C} -> ensure_leader(S#{conn => C});
        {error, _} -> S
    end;
ensure_leader(S = #{conn := C}) ->
    case epgsql:squery(C, io_lib:format("SELECT pg_try_advisory_lock(~b)", [?LOCK_KEY])) of
        {ok, _, [{<<"t">>}]} ->
            logger:notice("scheduler: this node (~s) is the leader", [node_name()]),
            reconcile(),
            S#{leader => true};
        _ -> S
    end.

%% Running occurrences left by a previous leader are settled from the audit.
%% Only the leader runs workers, so a new leader owns none: whatever is still
%% "running" belonged to a previous leader. A worker that is in fact alive
%% overwrites this with its real outcome when it finishes.
reconcile() ->
    _ = ana_db:exec(unicode:characters_to_binary(
        "UPDATE scheduler.occurrence o SET "
        "  status = CASE WHEN e.status = 'success' THEN 'success' ELSE 'error' END, "
        "  finished_at = COALESCE(e.finished_at, now()), "
        "  error = CASE WHEN e.status = 'success' THEN NULL ELSE COALESCE(e.error, "
        "    '{\"code\": \"INTERRUPTED\", \"message\": \"execução interrompida (troca de nó)\"}'::jsonb) END "
        "FROM scheduler.occurrence o2 LEFT JOIN ana_system.execution e ON e.id = o2.execution_id "
        "WHERE o.id = o2.id AND o.status = 'running'"), []),
    ok.

node_name() -> ana_config:node_id().

%% ==========================================================================
%% Work
%% ==========================================================================

work(S) ->
    case ana_mode:routines_suspended() of
        true -> S;                                % spec 077 (D14): suspended — what is due waits for the resume
        false ->
            materialize(),
            S2 = launch(S),
            late_warnings(),
            S2
    end.

%% 1. Due triggers → pending occurrences (RF-018-04).
materialize() ->
    {ok, Due} = ana_db:rows(
        "SELECT t.id, t.job_id, t.kind, t.cron, t.interval_s, t.fire_at, t.rule, t.nth, t.at_time::text AS at_time, "
        "  t.business_days_only, t.ends_at, extract(epoch FROM t.next_at)::bigint AS next_s, "
        "  j.timezone, j.missed, j.max_catchup "
        "FROM scheduler.trigger t JOIN scheduler.job j ON j.id = t.job_id "
        "WHERE t.next_at <= now() AND j.active AND t.kind <> 'after_job' ORDER BY t.next_at LIMIT 200", []),
    case Due of
        [] -> ok;
        _ ->
            Holidays = ana_schedule:holidays_list(),
            Now = erlang:system_time(second),
            _ = [materialize_trigger(T#{<<"holidays">> => Holidays}, Now) || T <- Due],
            ok
    end.

materialize_trigger(T = #{<<"id">> := Tid, <<"job_id">> := Job, <<"next_s">> := First,
                          <<"missed">> := Missed, <<"max_catchup">> := Max}, Now) ->
    Times = due_times(T, First, Now, min(Max, 1000) + 1, []),
    Last = lists:last(Times),
    Next = ana_schedule:next_after(T, Last),
    {Run, Skip} = case [X || X <- Times, X < Now - ?GRACE_S] of
        [] -> {Times, []};
        _MissedTimes ->
            case Missed of
                <<"run_all">> -> {lists:reverse(lists:sublist(lists:reverse(Times), Max)), []};
                <<"run_once">> -> {[Last], []};
                <<"skip">> -> {[], [Last]}
            end
    end,
    Reason = case length(Times) > 1 of
        true -> unicode:characters_to_binary(io_lib:format("~b ocorrência(s) perdida(s), política ~s", [length(Times) - 1, Missed]));
        false -> null
    end,
    RunReason = case {Missed, length(Run) > 1} of
        {<<"run_all">>, true} -> <<"catch-up">>;
        _ -> Reason
    end,
    _ = [insert_occurrence(Job, Tid, X, <<"pending">>, RunReason) || X <- Run],
    _ = [insert_occurrence(Job, Tid, X, <<"skipped">>, <<"missed">>) || X <- Skip],
    {ok, _} = ana_db:exec(
        "UPDATE scheduler.trigger SET next_at = to_timestamp($2), last_at = to_timestamp($3) WHERE id = $1",
        [Tid, case Next of undefined -> null; _ -> Next end, Last]),
    ok.

due_times(_T, undefined, _Now, _N, Acc) -> lists:reverse(Acc);
due_times(_T, S, Now, _N, Acc) when S > Now, Acc =/= [] -> lists:reverse(Acc);
due_times(_T, _S, _Now, 0, Acc) -> lists:reverse(Acc);
due_times(T, S, Now, N, Acc) ->
    due_times(T, ana_schedule:next_after(T, S), Now, N - 1, [S | Acc]).

insert_occurrence(Job, Trigger, At, Status, Reason) ->
    ana_db:exec(
        "INSERT INTO scheduler.occurrence (job_id, trigger_id, scheduled_at, status, reason) "
        "VALUES ($1, $2, to_timestamp($3), $4, $5) ON CONFLICT DO NOTHING",
        [Job, Trigger, At, Status, Reason]).

%% 2. Pending occurrences → executions (RF-018-03, window of RF-018-02).
launch(S) ->
    {ok, Pending} = ana_db:rows(
        "SELECT o.id, o.job_id, o.attempt, o.reason, j.concurrency, j.max_parallel, "
        "  (SELECT count(*) FROM scheduler.occurrence r WHERE r.job_id = o.job_id AND r.status = 'running') AS running, "
        "  (SELECT count(*) FROM scheduler.occurrence p WHERE p.job_id = o.job_id AND p.status = 'pending' "
        "     AND (p.run_after, p.id) < (o.run_after, o.id)) AS ahead, "
        "  (j.window_start IS NULL OR CASE WHEN j.window_start <= j.window_end "
        "     THEN (now() AT TIME ZONE j.timezone)::time BETWEEN j.window_start AND j.window_end "
        "     ELSE (now() AT TIME ZONE j.timezone)::time >= j.window_start "
        "       OR (now() AT TIME ZONE j.timezone)::time <= j.window_end END) AS in_window "
        "FROM scheduler.occurrence o JOIN scheduler.job j ON j.id = o.job_id "
        "WHERE o.status = 'pending' AND o.run_after <= now() AND j.active "
        "ORDER BY o.run_after, o.id LIMIT 100", []),
    {S2, _} = lists:foldl(fun decide/2, {S, #{}}, Pending),
    S2.

%% Started: occurrences started in this same tick, per job (the counts read
%% from the database do not include them yet).
decide(#{<<"in_window">> := false}, Acc) -> Acc;
decide(O = #{<<"id">> := Id, <<"job_id">> := Job, <<"concurrency">> := Conc, <<"running">> := Running0,
             <<"max_parallel">> := MaxP, <<"ahead">> := Ahead}, {S, Started}) ->
    Running = Running0 + maps:get(Job, Started, 0),
    Waitable = waitable(O),
    Action = case Conc of
        <<"skip">> when Running > 0, Waitable -> wait;
        <<"skip">> when Running > 0 -> {skip, <<"concurrent">>};
        <<"queue">> when Running > 0, Ahead > 0, not Waitable -> {skip, <<"queue_full">>};
        <<"queue">> when Running > 0 -> wait;
        <<"parallel">> when Running >= MaxP -> wait;
        _ when Ahead > 0, Conc =/= <<"parallel">> -> wait;
        _ -> start
    end,
    case Action of
        wait -> {S, Started};
        {skip, Reason} -> _ = skip(Id, Reason), {S, Started};
        start -> {start(O, S), Started#{Job => maps:get(Job, Started, 0) + 1}}
    end.

%% Catch-ups, retries, dependents and manual runs wait instead of being skipped.
waitable(#{<<"attempt">> := A}) when A > 1 -> true;
waitable(#{<<"reason">> := <<"catch-up">>}) -> true;
waitable(#{<<"reason">> := <<"after_job">>}) -> true;
waitable(#{<<"reason">> := <<"manual: ", _/binary>>}) -> true;
waitable(_) -> false.

skip(Id, Reason) ->
    ana_db:exec("UPDATE scheduler.occurrence SET status = 'skipped', reason = $2, finished_at = now() "
                "WHERE id = $1 AND status = 'pending'", [Id, Reason]).

start(#{<<"id">> := Id}, S = #{workers := W}) ->
    case ana_db:exec("UPDATE scheduler.occurrence SET status = 'running', started_at = now(), node = $2 "
                     "WHERE id = $1 AND status = 'pending'", [Id, node_name()]) of
        {ok, 1} ->
            {Pid, _} = spawn_monitor(fun() -> ana_scheduler_worker:run(Id) end),
            S#{workers => W#{Pid => Id}};
        _ -> S
    end.

%% 3. Late warnings (RF-018-08).
late_warnings() ->
    {ok, Late} = ana_db:rows(
        "UPDATE scheduler.occurrence o SET late_notified = true FROM scheduler.job j "
        "WHERE j.id = o.job_id AND o.status = 'pending' AND NOT o.late_notified "
        "  AND o.run_after < now() - make_interval(secs => j.late_after_s) "
        "RETURNING o.id, o.job_id, j.name, o.scheduled_at", []),
    _ = [ana_scheduler_worker:notify(Job, <<"late">>,
             <<"rotina ", Name/binary, " atrasada: prevista para ", (iso(At))/binary, " ainda não iniciou"/utf8>>, Id)
         || #{<<"id">> := Id, <<"job_id">> := Job, <<"name">> := Name, <<"scheduled_at">> := At} <- Late],
    ok.

iso(B) when is_binary(B) -> B;
iso(_) -> <<"?">>.
