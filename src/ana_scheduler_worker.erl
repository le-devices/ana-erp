%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Runs one scheduler occurrence (spec 018): executes the program as the job's
%% technical user with the job's limits, records the result, retries with
%% exponential backoff, notifies, pauses on exhaustion and fires dependent
%% jobs (RF-018-05, RF-018-06, RF-018-08).
-module(ana_scheduler_worker).
-export([run/1, notify/4, render/2]).

run(OccId) ->
    {ok, O} = ana_db:one(
        "SELECT o.id, o.job_id, o.attempt, o.scheduled_at, o.params AS override, j.name, j.program, j.params, j.variant_id, "
        "  j.run_as, j.limits, j.retries, j.retry_backoff_s, j.on_exhausted, j.timezone, u.role "
        "FROM scheduler.occurrence o JOIN scheduler.job j ON j.id = o.job_id "
        "JOIN ana_system.app_user u ON u.username = j.run_as "
        "WHERE o.id = $1", [OccId]),
    User = #{username => maps:get(<<"run_as">>, O), role => maps:get(<<"role">>, O)},
    Params = render(maps:merge(maps:get(<<"params">>, O),
                               case maps:get(<<"override">>, O) of M when is_map(M) -> M; _ -> #{} end),
                    maps:get(<<"timezone">>, O), maps:get(username, User)),
    Started = erlang:monotonic_time(millisecond),
    %% Spec 045 (CA-045-03): a job with a variant runs with its values resolved on the day of the run; the job's own
    %% parameters fill the free fields only.
    Result = case maps:get(<<"variant_id">>, O) of
        null -> ana_execution:run(maps:get(<<"program">>, O), Params, User,
                                  #{origin => <<"internal">>, limits => maps:get(<<"limits">>, O)});
        V ->
            case ana_variants:apply(maps:get(<<"program">>, O), V, Params, User) of
                {ok, P2, Info} -> ana_execution:run(maps:get(<<"program">>, O), P2, User,
                                                    #{origin => <<"internal">>, limits => maps:get(<<"limits">>, O), variant => Info});
                {error, Code, Msg} -> {error, #{<<"code">> => Code, <<"message">> => Msg}}
            end
    end,
    Duration = erlang:monotonic_time(millisecond) - Started,
    finish(O, Result, Duration).

finish(O = #{<<"id">> := Id, <<"job_id">> := Job}, {ok, #{id := ExecId, result := Result}}, Duration) ->
    {ok, _} = ana_db:exec(
        "UPDATE scheduler.occurrence SET status = 'success', finished_at = now(), execution_id = $2::text::uuid, "
        "  result = $3::text::jsonb WHERE id = $1",
        [Id, ExecId, iolist_to_binary(json:encode(Result))]),
    anomaly(O, Duration),
    dependents(Job, success, Result),
    ok;
finish(O = #{<<"id">> := Id, <<"job_id">> := Job, <<"attempt">> := Attempt, <<"retries">> := Retries,
             <<"name">> := Name}, {error, Error}, _Duration) ->
    Clean = maps:without([<<"events">>], Error),
    {ok, _} = ana_db:exec(
        "UPDATE scheduler.occurrence SET status = 'error', finished_at = now(), "
        "  execution_id = $2::text::uuid, error = $3::text::jsonb WHERE id = $1",
        [Id, maps:get(<<"execution_id">>, Clean, null), iolist_to_binary(json:encode(Clean))]),
    case Attempt =< Retries of
        true ->
            %% RF-018-05: exponential backoff.
            Delay = maps:get(<<"retry_backoff_s">>, O) * (1 bsl (Attempt - 1)),
            _ = ana_db:exec(
                "INSERT INTO scheduler.occurrence (job_id, trigger_id, scheduled_at, attempt, run_after, params, reason) "
                "SELECT job_id, trigger_id, scheduled_at, attempt + 1, now() + make_interval(secs => $2), params, "
                "  'retry' FROM scheduler.occurrence WHERE id = $1 ON CONFLICT DO NOTHING", [Id, Delay]),
            ok;
        false ->
            Code = maps:get(<<"code">>, Clean, <<"ERROR">>),
            notify(Job, <<"failure">>, <<"rotina ", Name/binary, " falhou após "/utf8, (integer_to_binary(Attempt))/binary,
                                         " tentativa(s): ", Code/binary, " — "/utf8,
                                         (maps:get(<<"message">>, Clean, <<>>))/binary>>, Id),
            case maps:get(<<"on_exhausted">>, O) of
                <<"pause">> ->
                    {ok, _} = ana_db:exec("UPDATE scheduler.job SET active = false, updated_at = now() WHERE id = $1",
                                          [Job]),
                    notify(Job, <<"paused">>, <<"rotina ", Name/binary, " pausada após falhas"/utf8>>, Id);
                _ -> ok
            end,
            dependents(Job, failure, Clean)
    end.

%% RF-018-06: jobs triggered after this one, with the result as a parameter.
dependents(Job, Outcome, Payload) ->
    Conditions = case Outcome of
        success -> [<<"success">>, <<"always">>];
        failure -> [<<"failure">>, <<"always">>]
    end,
    {ok, Ts} = ana_db:rows(
        "SELECT t.id, t.job_id, t.result_param FROM scheduler.trigger t JOIN scheduler.job j ON j.id = t.job_id "
        "WHERE t.kind = 'after_job' AND t.after_job_id = $1 AND t.after_condition = ANY($2::text[]) AND j.active",
        [Job, Conditions]),
    _ = [ana_db:exec(
             "INSERT INTO scheduler.occurrence (job_id, trigger_id, scheduled_at, params, reason) "
             "VALUES ($1, $2, clock_timestamp(), $3::text::jsonb, 'after_job')",
             [Dep, Tid, case P of
                            null -> null;
                            _ -> iolist_to_binary(json:encode(#{P => Payload}))
                        end])
         || #{<<"id">> := Tid, <<"job_id">> := Dep, <<"result_param">> := P} <- Ts],
    ok.

%% RF-018-08: duration > 3x the average of the last 20 successful runs.
anomaly(#{<<"job_id">> := Job, <<"name">> := Name, <<"id">> := Id}, Duration) ->
    case ana_db:one(
           "SELECT count(*) AS n, avg(extract(epoch FROM finished_at - started_at) * 1000) AS avg_ms FROM ("
           "  SELECT started_at, finished_at FROM scheduler.occurrence "
           "  WHERE job_id = $1 AND status = 'success' AND id <> $2 ORDER BY finished_at DESC LIMIT 20) s",
           [Job, Id]) of
        {ok, #{<<"n">> := N, <<"avg_ms">> := Avg}} when N >= 5, Avg =/= null ->
            AvgMs = binary_to_float_safe(Avg),
            case Duration > 3 * AvgMs andalso Duration > 1000 of
                true ->
                    notify(Job, <<"anomaly">>, unicode:characters_to_binary(io_lib:format(
                        "rotina ~ts levou ~b ms (média recente ~b ms)", [Name, Duration, round(AvgMs)])), Id);
                false -> ok
            end;
        _ -> ok
    end.

binary_to_float_safe(B) when is_binary(B) ->
    try binary_to_float(B) catch error:badarg -> float(binary_to_integer(B)) end;
binary_to_float_safe(N) when is_number(N) -> float(N).

notify(Job, Kind, Message, OccId) ->
    _ = ana_db:exec("INSERT INTO scheduler.notification (job_id, kind, message, occurrence_id) VALUES ($1, $2, $3, $4)",
                    [Job, Kind, Message, OccId]),
    %% Optional notification program (e-mail/webhook via connectors, spec 017).
    case ana_db:one("SELECT j.notify_program, j.run_as, j.name, u.role FROM scheduler.job j "
                    "JOIN ana_system.app_user u ON u.username = j.run_as "
                    "WHERE j.id = $1 AND j.notify_program IS NOT NULL", [Job]) of
        {ok, #{<<"notify_program">> := P, <<"run_as">> := U, <<"role">> := R, <<"name">> := Name}} ->
            _ = spawn(fun() ->
                ana_execution:run(P, #{<<"job">> => Name, <<"kind">> => Kind, <<"message">> => Message},
                                  #{username => U, role => R}, #{origin => <<"internal">>})
            end),
            ok;
        _ -> ok
    end.

%% Date templates in string parameters, in the job's time zone. Spec 065 (RF-065-11): "{{today}}" and the others
%% are cases of the closed list of expressions, resolved by its only implementation in the database; what is not
%% in the list stays as it was.
render(Params, Tz) -> render(Params, Tz, null).

%% Spec 065 (T-065-07): "{{valor:nome}}" is the company value in effect, for the job's user. A parameter that is only
%% the reference receives the value in its type (a list stays a list); inside a text, its text.
render(Params, Tz, User) ->
    P1 = case lists:usort(tokens(Params)) of
        [] -> Params;
        Tokens ->
            case ana_db:rows("SELECT t, ana_system.value_expression(t, NULL, $2, false, $3) AS v FROM unnest($1::text[]) t",
                             [Tokens, Tz, User]) of
                {ok, Rows} -> subst(Params, maps:from_list([{T, V} || #{<<"t">> := T, <<"v">> := V} <- Rows, V =/= null]));
                _ -> Params
            end
    end,
    ana_flows:company_values(P1, User).

tokens(M) when is_map(M) -> lists:append([tokens(V) || V <- maps:values(M)]);
tokens(L) when is_list(L) -> lists:append([tokens(V) || V <- L]);
tokens(B) when is_binary(B) ->
    case re:run(B, <<"\\{\\{([a-z_]+(?:[+-][0-9]{1,4})?)\\}\\}">>, [global, {capture, all_but_first, binary}]) of
        {match, Ms} -> [T || [T] <- Ms];
        nomatch -> []
    end;
tokens(_) -> [].

subst(M, Vars) when is_map(M) -> maps:map(fun(_, V) -> subst(V, Vars) end, M);
subst(L, Vars) when is_list(L) -> [subst(V, Vars) || V <- L];
subst(B, Vars) when is_binary(B) ->
    maps:fold(fun(K, V, Acc) -> binary:replace(Acc, <<"{{", K/binary, "}}">>, V, [global]) end, B, Vars);
subst(V, _) -> V.
