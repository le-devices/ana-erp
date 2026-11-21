%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Scheduled routines: storage, validation and occurrence calculation (spec 018).
%%
%% Local-time arithmetic is done by ana_cron; conversion between local time
%% and UTC uses PostgreSQL's zone database (RNF-018-02): nonexistent local
%% times (clock moved forward) are shifted forward and repeated ones are
%% converted once — nothing runs twice, nothing silently disappears.
-module(ana_schedule).
-export([list_jobs/1, get_job/1, save_job/3, delete_job/2, set_active/3, skip_next/2,
         run_now/3, preview/2, occurrences/2,
         holidays/0, save_holiday/3, delete_holiday/2,
         notifications/2, mark_read/2,
         next_after/2, holidays_list/0]).

-define(KINDS, [<<"cron">>, <<"interval">>, <<"once">>, <<"calendar">>, <<"after_job">>]).

%% ==========================================================================
%% Queries
%% ==========================================================================

list_jobs(Filter) ->
    ana_db:rows(
        "SELECT j.id, j.name, j.description, j.program, j.run_as, j.active, j.concurrency, j.timezone, "
        "  j.owner, j.retries, "
        "  (SELECT min(t.next_at) FROM scheduler.trigger t WHERE t.job_id = j.id) AS next_at, "
        "  (SELECT o.status FROM scheduler.occurrence o WHERE o.job_id = j.id AND o.status NOT IN ('pending') "
        "   ORDER BY o.scheduled_at DESC, o.attempt DESC LIMIT 1) AS last_status, "
        "  (SELECT max(o.finished_at) FROM scheduler.occurrence o WHERE o.job_id = j.id) AS last_run, "
        "  (SELECT count(*) FROM scheduler.notification n WHERE n.job_id = j.id AND NOT n.read) AS unread "
        "FROM scheduler.job j WHERE ($1::text IS NULL OR j.program = $1) ORDER BY j.name",
        [maps:get(<<"program">>, Filter, null)]).

get_job(Id) ->
    case ana_db:one("SELECT j.*, j.window_start::text AS window_start, j.window_end::text AS window_end "
                    "FROM scheduler.job j WHERE j.id = $1", [Id]) of
        {ok, undefined} -> {error, not_found};
        {ok, Job} ->
            {ok, Triggers} = ana_db:rows(
                "SELECT t.id, t.kind, t.cron, t.interval_s, t.fire_at, t.rule, t.nth, t.at_time::text AS at_time, "
                "  a.name AS after_job, t.after_condition, t.result_param, t.business_days_only, "
                "  t.starts_at, t.ends_at, t.next_at, t.last_at "
                "FROM scheduler.trigger t LEFT JOIN scheduler.job a ON a.id = t.after_job_id "
                "WHERE t.job_id = $1 ORDER BY t.id", [Id]),
            {ok, Job#{<<"triggers">> => Triggers}};
        E -> E
    end.

occurrences(Id, Limit) ->
    ana_db:rows(
        "SELECT id, scheduled_at, attempt, status, run_after, execution_id::text AS execution_id, node, "
        "  started_at, finished_at, "
        "  (extract(epoch FROM finished_at - started_at) * 1000)::bigint AS duration_ms, "
        "  result, error, reason "
        "FROM scheduler.occurrence WHERE job_id = $1 ORDER BY scheduled_at DESC, attempt DESC LIMIT $2",
        [Id, Limit]).

%% RF-018-07: next N occurrences across the job's time triggers.
preview(Id, N) ->
    case get_job(Id) of
        {ok, #{<<"timezone">> := Tz, <<"triggers">> := Ts}} ->
            Holidays = holidays_list(),
            Now = erlang:system_time(second),
            Times = lists:append([series(T, Tz, Holidays, Now, N) || T <- Ts]),
            {ok, [iso(S) || S <- lists:sublist(lists:usort(Times), N)]};
        E -> E
    end.

series(#{<<"kind">> := <<"after_job">>}, _, _, _, _) -> [];
series(T, Tz, Holidays, Now, N) ->
    First = case T of
        #{<<"next_at">> := Next} when is_binary(Next) -> parse_iso(Next);
        _ -> next_after(T#{<<"timezone">> => Tz, <<"holidays">> => Holidays}, Now)
    end,
    series_from(T#{<<"timezone">> => Tz, <<"holidays">> => Holidays}, First, N).

series_from(_T, undefined, _) -> [];
series_from(_T, _S, 0) -> [];
series_from(T, S, N) -> [S | series_from(T, next_after(T, S), N - 1)].

%% ==========================================================================
%% Next occurrence (UTC seconds) strictly after From (UTC seconds)
%% ==========================================================================

-spec next_after(map(), integer()) -> integer() | undefined.
next_after(T = #{<<"kind">> := Kind}, From) ->
    Next = case Kind of
        <<"interval">> -> From + maps:get(<<"interval_s">>, T);
        <<"once">> ->
            Fire = parse_iso(maps:get(<<"fire_at">>, T)),
            case Fire > From of true -> Fire; false -> undefined end;
        <<"cron">> ->
            {ok, Cron} = ana_cron:parse(maps:get(<<"cron">>, T)),
            Tz = maps:get(<<"timezone">>, T, <<"UTC">>),
            Local = to_local(From, Tz),
            R = case maps:get(<<"business_days_only">>, T, false) of
                true -> ana_cron:next_business(Cron, Local, maps:get(<<"holidays">>, T, []));
                false -> ana_cron:next(Cron, Local)
            end,
            case R of {ok, L} -> after_utc(to_utc(L, Tz), From, T); none -> undefined end;
        <<"calendar">> ->
            Tz = maps:get(<<"timezone">>, T, <<"UTC">>),
            [H, Mi | _] = [binary_to_integer(X) || X <- binary:split(maps:get(<<"at_time">>, T), <<":">>, [global])],
            Rule = binary_to_existing_atom(maps:get(<<"rule">>, T)),
            case ana_cron:next_calendar(Rule, maps:get(<<"nth">>, T, undefined), {H, Mi}, to_local(From, Tz),
                                        maps:get(<<"holidays">>, T, [])) of
                {ok, L} -> after_utc(to_utc(L, Tz), From, T);
                none -> undefined
            end;
        <<"after_job">> -> undefined
    end,
    within_bounds(Next, T).

%% A local time inside a "repeated hour" may map back to an instant not after
%% From; then we step one minute further (never duplicates, never loops).
after_utc(Utc, From, _T) when Utc > From -> Utc;
after_utc(_Utc, From, T) -> next_after(T, From + 60).

within_bounds(undefined, _) -> undefined;
within_bounds(S, T) ->
    case maps:get(<<"ends_at">>, T, null) of
        E when is_binary(E) ->
            case S > parse_iso(E) of true -> undefined; false -> S end;
        _ -> S
    end.

to_local(Utc, Tz) ->
    {ok, [{L}]} = conv("SELECT (to_timestamp($1) AT TIME ZONE $2)", [Utc, Tz]),
    trunc_dt(L).

to_utc({{Y, M, D}, {H, Mi, S}}, Tz) ->
    Text = io_lib:format("~4..0b-~2..0b-~2..0b ~2..0b:~2..0b:~2..0b", [Y, M, D, H, Mi, trunc(S)]),
    {ok, [{E}]} = conv("SELECT extract(epoch FROM ($1::text::timestamp AT TIME ZONE $2))::bigint",
                       [iolist_to_binary(Text), Tz]),
    E.

conv(Sql, Params) ->
    ana_db:with_connection(fun(C) ->
        case epgsql:equery(C, Sql, Params) of
            {ok, _, Rows} -> {ok, Rows};
            Other -> Other
        end
    end).

trunc_dt({Date, {H, M, S}}) -> {Date, {H, M, trunc(S)}}.

holidays_list() ->
    case ana_db:with_connection(fun(C) -> epgsql:equery(C, "SELECT day FROM scheduler.holiday", []) end) of
        {ok, _, Rows} -> [D || {D} <- Rows];
        _ -> []
    end.

parse_iso(B) when is_binary(B) ->
    calendar:rfc3339_to_system_time(binary_to_list(normalize_iso(B)), [{unit, second}]).

normalize_iso(B) ->
    case binary:last(B) of
        $Z -> B;
        _ ->
            case re:run(B, "[+-][0-9]{2}:[0-9]{2}$", [{capture, none}]) of
                match -> B;
                nomatch -> <<B/binary, "Z">>
            end
    end.

iso(S) -> list_to_binary(calendar:system_time_to_rfc3339(S, [{offset, "Z"}])).

%% ==========================================================================
%% Saving (RF-018-01, RF-018-02, RF-018-09)
%% ==========================================================================

save_job(Id, Fields, User = #{username := Who}) ->
    case validate(Fields, User) of
        ok ->
            try ana_db:transaction(fun(C) -> write(C, Id, Fields, Who) end) of
                {ok, NewId} ->
                    ana_admin:log(Who, <<"scheduler.job.save">>, integer_to_binary(NewId), null,
                                  maps:without([<<"params">>], Fields)),
                    get_job(NewId);
                {error, #{sqlstate := <<"23505">>}} -> {error, <<"já existe uma rotina com esse nome"/utf8>>};
                {error, #{} = E} -> {error, E}
            catch throw:{invalid, Msg} -> {error, Msg};
                  throw:{db, E} -> {error, E}
            end;
        E -> E
    end.

validate(F, User = #{username := Who}) ->
    Program = maps:get(<<"program">>, F, null),
    RunAs = maps:get(<<"run_as">>, F, Who),
    Tz = maps:get(<<"timezone">>, F, list_to_binary(ana_config:timezone())),
    Checks = [
        {is_binary(maps:get(<<"name">>, F, null)), <<"informe o nome da rotina">>},
        {program_ok(Program), <<"programa inexistente, inativo ou biblioteca">>},
        {user_ok(RunAs), <<"usuário de execução inexistente ou inativo"/utf8>>},
        {RunAs =:= Who orelse ana_security:has_role(User, <<"admin">>),
         <<"executar como outro usuário exige papel admin"/utf8>>},
        {timezone_ok(Tz), <<"fuso horário inválido"/utf8>>},
        {is_list(maps:get(<<"triggers">>, F, [])), <<"triggers deve ser uma lista">>},
        {ana_limits:validate(maps:get(<<"limits">>, F, #{})) =:= ok, <<"limites inválidos"/utf8>>},
        {variant_ok(Program, maps:get(<<"variant_id">>, F, null), RunAs),
         <<"variante inexistente, de outra rotina ou que o usuário de execução não vê (use uma da empresa ou dele)"/utf8>>}
    ],
    case [M || {false, M} <- Checks] of
        [] -> lists:foldl(fun(T, ok) -> validate_trigger(T); (_, E) -> E end, ok, maps:get(<<"triggers">>, F, []));
        [M | _] -> {error, unicode:characters_to_binary(M)}
    end.

validate_trigger(#{<<"kind">> := K} = T) ->
    case lists:member(K, ?KINDS) of
        false -> {error, <<"tipo de gatilho inválido"/utf8>>};
        true when K =:= <<"cron">> ->
            case ana_cron:parse(maps:get(<<"cron">>, T, <<>>)) of
                {ok, _} -> ok;
                {error, _} = E -> E
            end;
        true -> ok
    end;
validate_trigger(_) -> {error, <<"gatilho sem tipo">>}.

variant_ok(_, null, _) -> true;
variant_ok(P, V, RunAs) when is_binary(P), is_integer(V) ->
    case ana_db:one("SELECT 1 AS ok FROM ana_system.run_variant WHERE id = $1 AND program = $2 "
                    "AND (owner = $3 OR (owner IS NULL AND published))", [V, P, RunAs]) of
        {ok, #{<<"ok">> := 1}} -> true;
        _ -> false
    end;
variant_ok(_, _, _) -> false.

program_ok(P) when is_binary(P) ->
    case ana_program:for_execution(P) of
        {ok, #{<<"kind">> := <<"program">>, <<"active">> := true}} -> true;
        _ -> false
    end;
program_ok(_) -> false.

user_ok(U) when is_binary(U) ->
    case ana_db:one("SELECT 1 AS ok FROM ana_system.app_user WHERE username = $1 AND active", [U]) of
        {ok, #{<<"ok">> := 1}} -> true;
        _ -> false
    end;
user_ok(_) -> false.

timezone_ok(Tz) when is_binary(Tz) ->
    case ana_db:one("SELECT now() AT TIME ZONE $1 AS t", [Tz]) of
        {ok, #{}} -> true;
        _ -> false
    end;
timezone_ok(_) -> false.

write(C, Id, F, Who) ->
    Tz = maps:get(<<"timezone">>, F, list_to_binary(ana_config:timezone())),
    Values = [maps:get(<<"name">>, F), maps:get(<<"description">>, F, <<>>), maps:get(<<"program">>, F),
              maps:get(<<"params">>, F, #{}), maps:get(<<"run_as">>, F, Who), maps:get(<<"limits">>, F, #{}),
              maps:get(<<"active">>, F, true), maps:get(<<"concurrency">>, F, <<"skip">>),
              maps:get(<<"max_parallel">>, F, 1), maps:get(<<"missed">>, F, <<"run_once">>),
              maps:get(<<"max_catchup">>, F, 10), maps:get(<<"retries">>, F, 0),
              maps:get(<<"retry_backoff_s">>, F, 60), maps:get(<<"on_exhausted">>, F, <<"notify">>),
              empty_null(maps:get(<<"window_start">>, F, null)), empty_null(maps:get(<<"window_end">>, F, null)),
              Tz, maps:get(<<"late_after_s">>, F, 300), empty_null(maps:get(<<"notify_program">>, F, null)),
              maps:get(<<"owner">>, F, Who)],
    JobId = case Id of
        new ->
            one(C, "INSERT INTO scheduler.job (name, description, program, params, run_as, limits, active, "
                   "  concurrency, max_parallel, missed, max_catchup, retries, retry_backoff_s, on_exhausted, "
                   "  window_start, window_end, timezone, late_after_s, notify_program, owner, created_by) "
                   "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15::text::time, "
                   "        $16::text::time, $17, $18, $19, $20, $21) RETURNING id", Values ++ [Who]);
        _ ->
            one(C, "UPDATE scheduler.job SET name = $2, description = $3, program = $4, params = $5, run_as = $6, "
                   "  limits = $7, active = $8, concurrency = $9, max_parallel = $10, missed = $11, "
                   "  max_catchup = $12, retries = $13, retry_backoff_s = $14, on_exhausted = $15, "
                   "  window_start = $16::text::time, window_end = $17::text::time, timezone = $18, "
                   "  late_after_s = $19, notify_program = $20, owner = $21, updated_at = now() "
                   "WHERE id = $1 RETURNING id", [Id | Values])
    end,
    JobId =:= undefined andalso throw({invalid, <<"rotina não encontrada"/utf8>>}),
    %% Spec 045 (D5): the job may run with a variant of its program (resolved at each run).
    _ = case maps:find(<<"variant_id">>, F) of
        {ok, Vid} -> {ok, _} = ana_db:query(C, "UPDATE scheduler.job SET variant_id = $2 WHERE id = $1 "
                                               "AND variant_id IS DISTINCT FROM $2", [JobId, Vid]);
        error -> ok
    end,
    {ok, _} = ana_db:query(C, "DELETE FROM scheduler.trigger WHERE job_id = $1", [JobId]),
    Holidays = holidays_list(),
    Now = erlang:system_time(second),
    _ = [insert_trigger(C, JobId, T, Tz, Holidays, Now) || T <- maps:get(<<"triggers">>, F, [])],
    {ok, JobId}.

insert_trigger(C, JobId, T, Tz, Holidays, Now) ->
    AfterJob = case maps:get(<<"after_job">>, T, null) of
        null -> null;
        Name ->
            case one(C, "SELECT id FROM scheduler.job WHERE name = $1", [Name]) of
                undefined -> throw({invalid, <<"rotina de origem (after_job) não encontrada"/utf8>>});
                Aid -> Aid
            end
    end,
    StartsAt = maps:get(<<"starts_at">>, T, null),
    %% First occurrence: starts_at when given (it may lie in the past and then
    %% counts as missed), otherwise the next one after now.
    NextAt = case maps:get(<<"kind">>, T) of
        <<"after_job">> -> undefined;
        <<"once">> -> parse_iso(maps:get(<<"fire_at">>, T));
        _ when is_binary(StartsAt) -> first_from(T, Tz, Holidays, parse_iso(StartsAt) - 1);
        _ -> first_from(T, Tz, Holidays, Now)
    end,
    {ok, _} = ana_db:query(C,
        "INSERT INTO scheduler.trigger (job_id, kind, cron, interval_s, fire_at, rule, nth, at_time, after_job_id, "
        "  after_condition, result_param, business_days_only, starts_at, ends_at, next_at) "
        "VALUES ($1, $2, $3, $4, $5::text::timestamptz, $6, $7, $8::text::time, $9, $10, $11, $12, "
        "        $13::text::timestamptz, $14::text::timestamptz, to_timestamp($15))",
        [JobId, maps:get(<<"kind">>, T), maps:get(<<"cron">>, T, null), maps:get(<<"interval_s">>, T, null),
         maps:get(<<"fire_at">>, T, null), maps:get(<<"rule">>, T, null), maps:get(<<"nth">>, T, null),
         empty_null(maps:get(<<"at_time">>, T, null)), AfterJob, maps:get(<<"after_condition">>, T, null),
         empty_null(maps:get(<<"result_param">>, T, null)), maps:get(<<"business_days_only">>, T, false),
         StartsAt, maps:get(<<"ends_at">>, T, null), case NextAt of undefined -> null; _ -> NextAt end]).

first_from(T = #{<<"kind">> := <<"interval">>}, _Tz, _Hol, From) ->
    case maps:get(<<"starts_at">>, T, null) of
        S when is_binary(S) -> parse_iso(S);
        _ -> From + maps:get(<<"interval_s">>, T)
    end;
first_from(T, Tz, Holidays, From) ->
    next_after(T#{<<"timezone">> => Tz, <<"holidays">> => Holidays}, From).

one(C, Sql, Params) ->
    case ana_db:query(C, Sql, Params) of
        {ok, #{rows := [[V | _] | _]}} -> V;
        {ok, _} -> undefined;
        {error, E} -> throw({db, E})
    end.

empty_null(<<>>) -> null;
empty_null(V) -> V.

delete_job(Id, #{username := Who}) ->
    {ok, N} = ana_db:exec("DELETE FROM scheduler.job WHERE id = $1", [Id]),
    ana_admin:log(Who, <<"scheduler.job.delete">>, integer_to_binary(Id), null, null),
    {ok, #{deleted => N}}.

set_active(Id, Active, #{username := Who}) ->
    {ok, N} = ana_db:exec("UPDATE scheduler.job SET active = $2, updated_at = now() WHERE id = $1", [Id, Active]),
    ana_admin:log(Who, case Active of true -> <<"scheduler.job.resume">>; false -> <<"scheduler.job.pause">> end,
                  integer_to_binary(Id), null, null),
    case N of 1 -> {ok, #{active => Active}}; _ -> {error, not_found} end.

%% RF-018-07: skips the next occurrence of each time trigger.
skip_next(Id, #{username := Who}) ->
    case get_job(Id) of
        {ok, #{<<"timezone">> := Tz, <<"triggers">> := Ts}} ->
            Holidays = holidays_list(),
            Skipped = lists:filtermap(fun
                (T = #{<<"id">> := Tid, <<"next_at">> := Next}) when is_binary(Next) ->
                    S = parse_iso(Next),
                    New = next_after(T#{<<"timezone">> => Tz, <<"holidays">> => Holidays}, S),
                    {ok, _} = ana_db:exec(
                        "INSERT INTO scheduler.occurrence (job_id, trigger_id, scheduled_at, status, reason) "
                        "VALUES ($1, $2, to_timestamp($3), 'skipped', 'skip_next') ON CONFLICT DO NOTHING",
                        [Id, Tid, S]),
                    {ok, _} = ana_db:exec("UPDATE scheduler.trigger SET next_at = to_timestamp($2) WHERE id = $1",
                                          [Tid, case New of undefined -> null; _ -> New end]),
                    {true, iso(S)};
                (_) -> false
            end, Ts),
            ana_admin:log(Who, <<"scheduler.job.skip_next">>, integer_to_binary(Id), null, #{skipped => Skipped}),
            {ok, #{skipped => Skipped}};
        E -> E
    end.

%% RF-018-07: run now (optionally with other parameters) as a pending occurrence.
run_now(Id, Params, #{username := Who}) ->
    case ana_db:one(
           "INSERT INTO scheduler.occurrence (job_id, scheduled_at, params, reason) "
           "SELECT id, clock_timestamp(), $2::text::jsonb, $3 FROM scheduler.job WHERE id = $1 RETURNING id",
           [Id, case Params of null -> null; _ -> iolist_to_binary(json:encode(Params)) end,
            <<"manual: ", Who/binary>>]) of
        {ok, #{<<"id">> := Occ}} ->
            ana_admin:log(Who, <<"scheduler.job.run_now">>, integer_to_binary(Id), null, null),
            {ok, #{occurrence => Occ}};
        {ok, undefined} -> {error, not_found};
        E -> E
    end.

%% ==========================================================================
%% Holidays and notifications
%% ==========================================================================

holidays() ->
    ana_db:rows("SELECT day, description FROM scheduler.holiday ORDER BY day", []).

save_holiday(Day, Description, #{username := Who}) ->
    R = ana_db:exec("INSERT INTO scheduler.holiday (day, description) VALUES ($1, $2) "
                    "ON CONFLICT (day) DO UPDATE SET description = EXCLUDED.description", [Day, Description]),
    ana_admin:log(Who, <<"scheduler.holiday.save">>, Day, null, Description),
    R.

delete_holiday(Day, #{username := Who}) ->
    ana_admin:log(Who, <<"scheduler.holiday.delete">>, Day, null, null),
    ana_db:exec("DELETE FROM scheduler.holiday WHERE day = $1", [Day]).

notifications(User = #{username := Who}, OnlyUnread) ->
    ana_db:rows(
        "SELECT n.id, n.kind, n.message, n.read, n.created_at, j.id AS job_id, j.name AS job, j.program "
        "FROM scheduler.notification n JOIN scheduler.job j ON j.id = n.job_id "
        "WHERE ($1 OR j.owner = $2) AND (NOT $3 OR NOT n.read) ORDER BY n.created_at DESC LIMIT 100",
        [ana_security:has_role(User, <<"admin">>), Who, OnlyUnread]).

mark_read(Id, User = #{username := Who}) ->
    ana_db:exec("UPDATE scheduler.notification n SET read = true FROM scheduler.job j "
                "WHERE n.id = $1 AND j.id = n.job_id AND ($2 OR j.owner = $3)",
                [Id, ana_security:has_role(User, <<"admin">>), Who]).
