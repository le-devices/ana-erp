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

%% Fun() -> {ok, Detail} | {error, Reason} | ok. Exceptions are caught,
%% recorded and returned as {error, _}: a failing task never takes down its caller.
-spec run(binary(), map(), binary(), fun(() -> term())) -> {ok, term()} | {error, term()}.
run(Task, #{username := Owner}, Origin, Fun) ->
    Id = case ana_db:one("INSERT INTO ana_system.task_run (task, username, origin, status) "
                         "VALUES ($1, $2, $3, 'running') RETURNING id", [Task, Owner, Origin]) of
        {ok, #{<<"id">> := I}} -> I;
        {error, E} -> logger:error("task_run (start) failed: ~0p", [E]), undefined
    end,
    Result = try Fun() of
        ok -> {ok, null};
        {ok, _} = R -> R;
        {error, _} = R -> R;
        Other -> {ok, Other}
    catch Class:Reason:Stack ->
        logger:error("task ~ts failed: ~0p:~0p ~0p", [Task, Class, Reason, Stack]),
        {error, {Class, Reason}}
    end,
    {Status, Detail} = case Result of
        {ok, D} -> {<<"success">>, D};
        {error, D} -> {<<"error">>, D}
    end,
    _ = Id =/= undefined andalso
        ana_db:exec("UPDATE ana_system.task_run SET status = $2, finished_at = now(), detail = $3 "
                    "WHERE id = $1", [Id, Status, detail(Detail)]),
    Result.

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
