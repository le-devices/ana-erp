%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Internal tasks with an owner (constitution P14, RF-011-16).
%%
%% Work that is not a program execution (seeding, analytics refresh…) is
%% recorded in ana_system.task_run under a real user: whoever asked for it, or
%% the built-in robot "system" when the ERP itself runs it.
-module(ana_task).
-export([run/4, system_user/0, list/1]).

-define(SYSTEM, <<"system">>).

-spec system_user() -> map().
system_user() ->
    #{username => ?SYSTEM, role => <<"developer">>, kind => <<"robot">>}.

%% Fun() -> {ok, Detail} | {error, Reason} | ok | {skip, Detail}. Exceptions are caught,
%% recorded and returned as {error, _}: a failing task never takes down its caller.
%%
%% Disk endurance (spec 063, P15): a short task is written once, already finished. Only a task
%% still running after ?VISIBLE_MS gets its 'running' row (so long work stays visible), finished
%% later with an UPDATE. {skip, Detail} means there was nothing to do: nothing is written.
-define(VISIBLE_MS, 2000).

-spec run(binary(), map(), binary(), fun(() -> term())) -> {ok, term()} | {error, term()}.
run(Task, #{username := Owner}, Origin, Fun) ->
    Watch = watch(Task, Owner, Origin),
    Result = try Fun() of
        ok -> {ok, null};
        {ok, _} = R -> R;
        {error, _} = R -> R;
        {skip, _} = R -> R;
        Other -> {ok, Other}
    catch Class:Reason:Stack ->
        logger:error("task ~ts failed: ~0p:~0p ~0p", [Task, Class, Reason, Stack]),
        {error, {Class, Reason}}
    end,
    record(Task, Owner, Origin, unwatch(Watch), Result),
    case Result of
        {skip, D} -> {ok, D};
        _ -> Result
    end.

%% A helper that writes the 'running' row only if the task outlives ?VISIBLE_MS. Messages are
%% handled in order, so the caller always learns whether that row exists.
watch(Task, Owner, Origin) ->
    Caller = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        MRef = monitor(process, Caller),
        receive
            {done, Ref} -> Caller ! {Ref, undefined};
            {'DOWN', MRef, _, _, _} -> ok
        after ?VISIBLE_MS ->
            Id = case ana_db:one("INSERT INTO ana_system.task_run (task, username, origin, status) "
                                 "VALUES ($1, $2, $3, 'running') RETURNING id", [Task, Owner, Origin]) of
                {ok, #{<<"id">> := I}} -> I;
                {error, E} -> logger:error("task_run (start) failed: ~0p", [E]), undefined
            end,
            receive
                {done, Ref} -> Caller ! {Ref, Id};
                {'DOWN', MRef, _, _, _} -> ok
            end
        end
    end),
    {Pid, Ref, erlang:system_time(microsecond)}.

unwatch({Pid, Ref, Started}) ->
    MRef = monitor(process, Pid),
    Pid ! {done, Ref},
    receive
        {Ref, Id} -> demonitor(MRef, [flush]), {Id, Started};
        {'DOWN', MRef, _, _, _} -> {undefined, Started}
    end.

record(_, _, _, {undefined, _}, {skip, _}) -> ok;
record(_, _, _, {Id, _}, {skip, D}) ->
    finish(Id, <<"success">>, D);
record(Task, Owner, Origin, {undefined, Started}, Result) ->
    {Status, Detail} = status(Result),
    case ana_db:exec("INSERT INTO ana_system.task_run (task, username, origin, status, started_at, finished_at, detail) "
                     "VALUES ($1, $2, $3, $4, to_timestamp($5::bigint / 1e6), now(), $6)",
                     [Task, Owner, Origin, Status, Started, detail(Detail)]) of
        {ok, _} -> ok;
        {error, E} -> logger:error("task_run failed: ~0p", [E])
    end;
record(_, _, _, {Id, _}, Result) ->
    {Status, Detail} = status(Result),
    finish(Id, Status, Detail).

finish(Id, Status, Detail) ->
    _ = ana_db:exec("UPDATE ana_system.task_run SET status = $2, finished_at = now(), detail = $3 "
                    "WHERE id = $1", [Id, Status, detail(Detail)]),
    ok.

status({ok, D}) -> {<<"success">>, D};
status({error, D}) -> {<<"error">>, D}.

detail(null) -> null;
detail(B) when is_binary(B) -> B;
detail(T) -> unicode:characters_to_binary(io_lib:format("~0tp", [T])).

list(F) ->
    ana_db:rows(
        "SELECT task, username, origin, started_at, finished_at, status, detail, "
        "  (extract(epoch FROM finished_at - started_at) * 1000)::int AS duration_ms "
        "FROM ana_system.task_run "
        "WHERE ($1::text IS NULL OR username = $1) AND ($2::text IS NULL OR task LIKE $2 || '%') "
        "ORDER BY started_at DESC LIMIT $3",
        [maps:get(username, F, null), maps:get(task, F, null), maps:get(limit, F, 200)]).
