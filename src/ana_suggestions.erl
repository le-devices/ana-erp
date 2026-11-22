%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Suggestions from usage (spec 051, D3, RF-051-03, RNF-051-02; T-045-07b): the ERP notices what a person does again
%% and again and offers to do it. In the background, once an hour (leader only), it reads the executions since the last
%% mark into a daily aggregate (automation.usage_day) — never a cost in the execution itself — and looks for:
%%   - schedule: the same routine with the same values on 4 business days in a row, about the same time (±1 h);
%%   - variant: the same values 3 times in 30 days, typed again each time (no variant used).
%% Each suggestion explains itself in Portuguese and has a fingerprint per person: declined, it never comes back.
-module(ana_suggestions).
-behaviour(gen_server).

-export([start_link/0, run_now/0, mine/1, accept/3, decline/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(EVERY_MS, 3600000).
-define(DAYS, 30).
-define(SCHEDULE_DAYS, 4).
-define(VARIANT_RUNS, 3).
-define(WEEKDAY, [<<"segunda"/utf8>>, <<"terça"/utf8>>, <<"quarta"/utf8>>, <<"quinta"/utf8>>, <<"sexta"/utf8>>,
                  <<"sábado"/utf8>>, <<"domingo"/utf8>>]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    erlang:send_after(60000, self(), tick),
    {ok, #{}}.

%% Tests and the "analisar agora" of the central.
-spec run_now() -> {ok, map()} | {error, integer(), binary(), binary()}.
run_now() -> gen_server:call(?MODULE, run, 120000).

handle_call(run, _From, S) ->
    {reply, try {ok, analyze()}
            catch C:R:St ->
                logger:warning("suggestions: ~0p:~0p ~0p", [C, R, St]),
                {error, 500, <<"INTERNAL">>, <<"a análise do uso falhou (veja o log do núcleo)"/utf8>>}
            end, S};
handle_call(_, _From, S) -> {reply, {error, unknown}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(tick, S) ->
    erlang:send_after(?EVERY_MS, self(), tick),
    _ = leader() andalso is_pid(spawn(fun() -> try analyze() catch C:R:St ->
                                                   logger:warning("suggestions: ~0p:~0p ~0p", [C, R, St]) end end)),
    {noreply, S};
handle_info(_, S) -> {noreply, S}.

leader() ->
    case catch ana_scheduler:status() of
        #{leader := true} -> true;
        _ -> false
    end.

%% ---------------------------------------------------------------- analysis

analyze() ->
    Tz = ana_config:timezone(),
    {ok, Added} = aggregate(Tz),
    S = schedules(),
    V = variants(),
    {ok, _} = ana_db:exec("DELETE FROM automation.usage_day WHERE day < current_date - 60", []),
    #{<<"aggregated">> => Added, <<"schedule">> => S, <<"variant">> => V}.

%% Executions of people (no robots, rehearsals, debugging, simulations, nested calls), of routines of the menu.
aggregate(Tz) ->
    ana_db:transaction(fun(C) ->
        {ok, R} = ana_db:rows(C, "SELECT COALESCE((SELECT at FROM automation.mark WHERE name = 'usage' FOR UPDATE), "
                                 "  now() - make_interval(days => $1::int)) AS since, now() - interval '1 minute' AS until", [?DAYS]),
        [#{<<"since">> := Since, <<"until">> := Until}] = R,
        {ok, #{affected := N}} = ana_db:query(C,
            "INSERT INTO automation.usage_day AS u (day, username, program, params_hash, params, first_at, runs, variant) "
            "SELECT (e.started_at AT TIME ZONE $3)::date, e.username, e.program, md5(COALESCE(e.params, '{}')::text), "
            "  COALESCE(e.params, '{}'), min((e.started_at AT TIME ZONE $3)::time(0)), count(*), bool_or(e.variant IS NOT NULL) "
            "FROM ana_system.execution e "
            "JOIN ana_system.app_user a ON a.username = e.username AND a.kind = 'human' "
            "JOIN ana_system.program p ON p.name = e.program AND p.in_menu AND p.kind = 'program' "
            "WHERE e.started_at > $1 AND e.started_at <= $2 AND e.status = 'success' AND NOT e.debug "
            "  AND NOT COALESCE(e.rehearsal, false) AND e.parent_execution_id IS NULL AND e.origin IN ('studio', 'api') "
            "  AND e.program NOT LIKE 'simulation.%' "
            "GROUP BY 1, 2, 3, 4, 5 "
            "ON CONFLICT (day, username, program, params_hash) DO UPDATE SET runs = u.runs + EXCLUDED.runs, "
            "  first_at = least(u.first_at, EXCLUDED.first_at), variant = u.variant OR EXCLUDED.variant",
            [Since, Until, list_to_binary(Tz)]),
        {ok, _} = ana_db:query(C, "INSERT INTO automation.mark (name, at) VALUES ('usage', $1) "
                                  "ON CONFLICT (name) DO UPDATE SET at = EXCLUDED.at", [Until]),
        {ok, N}
    end).

%% CA-051-02: 4 business days in a row, the first run of each within an hour of the others.
schedules() ->
    {ok, Rows} = ana_db:rows(
        "SELECT u.username, u.program, u.params_hash, u.params, array_agg(u.day ORDER BY u.day) AS days, "
        "  array_agg(to_char(u.first_at, 'HH24:MI') ORDER BY u.day) AS times "
        "FROM automation.usage_day u WHERE u.day >= current_date - $1::int "
        "  AND NOT EXISTS (SELECT 1 FROM automation.suggestion s WHERE s.username = u.username "
        "                  AND s.fingerprint = 'schedule:' || u.program || ':' || u.params_hash) "
        "  AND NOT EXISTS (SELECT 1 FROM scheduler.job j WHERE j.program = u.program AND j.run_as = u.username) "
        "GROUP BY 1, 2, 3, 4 HAVING count(*) >= $2::int", [?DAYS, ?SCHEDULE_DAYS]),
    Holidays = holidays(),
    lists:foldl(fun(R = #{<<"days">> := Days, <<"times">> := Times}, N) ->
        Pairs = lists:zip([to_date(D) || D <- Days], [minutes(T) || T <- Times]),
        case best_run(Pairs, Holidays) of
            none -> N;
            {Run, At} -> N + suggest_schedule(R, Run, At)
        end
    end, 0, Rows).

%% The longest stretch of business days in a row (holidays do not break it), all within an hour of each other.
best_run(Pairs, Holidays) ->
    Runs = business_run(Pairs, Holidays),
    Good = [{Run, lists:min([M || {_, M} <- Run])} || Run <- Runs, length(Run) >= ?SCHEDULE_DAYS,
                                                       spread([M || {_, M} <- Run]) =< 60],
    case lists:reverse(lists:keysort(1, [{length(Run), {Run, At}} || {Run, At} <- Good])) of
        [{_, Best} | _] -> Best;
        [] -> none
    end.

%% Splits the days into stretches of consecutive business days (Mon–Fri, holidays skipped).
-spec business_run([{calendar:date(), integer()}], [calendar:date()]) -> [[{calendar:date(), integer()}]].
business_run([], _) -> [];
business_run([First | Rest], Hol) ->
    {Runs, Cur} = lists:foldl(fun(P = {D, _}, {Acc, [{Prev, _} | _] = C}) ->
                                      case next_business(Prev, Hol) =:= D of
                                          true -> {Acc, [P | C]};
                                          false -> {[lists:reverse(C) | Acc], [P]}
                                      end
                              end, {[], [First]}, Rest),
    lists:reverse([lists:reverse(Cur) | Runs]).

next_business(D, Hol) ->
    N = calendar:gregorian_days_to_date(calendar:date_to_gregorian_days(D) + 1),
    case calendar:day_of_the_week(N) > 5 orelse lists:member(N, Hol) of
        true -> next_business(N, Hol);
        false -> N
    end.

spread(L) -> lists:max(L) - lists:min(L).

suggest_schedule(#{<<"username">> := U, <<"program">> := P, <<"params_hash">> := H, <<"params">> := Params}, Run, At) ->
    {H24, M} = {At div 60, At rem 60},
    {First, _} = hd(Run),
    {Last, _} = lists:last(Run),
    When = iolist_to_binary(io_lib:format("~2..0B:~2..0B", [H24, M])),
    Label = label(P),
    Explain = iolist_to_binary([<<"Você executou "/utf8>>, Label, <<" com estes mesmos valores em "/utf8>>,
                                integer_to_binary(length(Run)), <<" dias úteis seguidos ("/utf8>>, day_text(First),
                                <<" a "/utf8>>, day_text(Last), <<"), sempre por volta das "/utf8>>, When,
                                <<". O ERP pode fazer isso por você de segunda a sexta nesse horário."/utf8>>]),
    insert(U, <<"schedule">>, <<"schedule:", P/binary, ":", H/binary>>, P,
           <<"Agendar "/utf8, Label/binary, " todo dia útil às "/utf8, When/binary>>, Explain,
           #{<<"params">> => Params, <<"cron">> => iolist_to_binary(io_lib:format("~b ~b * * 1-5", [M, H24])),
             <<"at">> => When}).

%% T-045-07b: the same values typed again, three times in 30 days, without a variant.
variants() ->
    {ok, Rows} = ana_db:rows(
        "SELECT u.username, u.program, u.params_hash, u.params, sum(u.runs)::int AS runs, count(*)::int AS days "
        "FROM automation.usage_day u WHERE u.day >= current_date - $1::int AND u.params <> '{}'::jsonb "
        "  AND NOT EXISTS (SELECT 1 FROM automation.suggestion s WHERE s.username = u.username "
        "                  AND s.fingerprint = 'variant:' || u.program || ':' || u.params_hash) "
        "  AND NOT EXISTS (SELECT 1 FROM ana_system.run_variant v WHERE v.program = u.program "
        "                  AND (v.owner = u.username OR v.owner IS NULL)) "
        "GROUP BY 1, 2, 3, 4 HAVING sum(u.runs) >= $2::int AND NOT bool_or(u.variant)", [?DAYS, ?VARIANT_RUNS]),
    lists:foldl(fun(#{<<"username">> := U, <<"program">> := P, <<"params_hash">> := H, <<"params">> := Params,
                      <<"runs">> := Runs}, N) ->
        Label = label(P),
        Explain = iolist_to_binary([<<"Você digitou os mesmos valores em "/utf8>>, Label, <<" "/utf8>>,
                                    integer_to_binary(Runs), <<" vezes nos últimos 30 dias ("/utf8>>, values_text(Params),
                                    <<"). Salve como variante e escolha pelo nome da próxima vez."/utf8>>]),
        N + insert(U, <<"variant">>, <<"variant:", P/binary, ":", H/binary>>, P,
                   <<"Salvar como variante: "/utf8, Label/binary>>, Explain, #{<<"params">> => Params})
    end, 0, Rows).

insert(U, Kind, Fp, P, Title, Explain, Payload) ->
    {ok, N} = ana_db:exec("INSERT INTO automation.suggestion (username, kind, fingerprint, program, title, explanation, payload) "
                          "VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT (username, fingerprint) DO NOTHING",
                          [U, Kind, Fp, P, Title, Explain, Payload]),
    N.

label(P) ->
    case ana_db:one("SELECT description FROM ana_system.program WHERE name = $1", [P]) of
        {ok, #{<<"description">> := D}} when is_binary(D), D =/= <<>> ->
            <<"\""/utf8, (hd(binary:split(D, [<<":">>, <<" — "/utf8>>])))/binary, "\" ("/utf8, P/binary, ")">>;
        _ -> P
    end.

values_text(Params) when is_map(Params) ->
    iolist_to_binary(lists:join(<<", ">>, [[K, <<" = ">>, val(V)] || {K, V} <- lists:sublist(lists:sort(maps:to_list(Params)), 4)]));
values_text(_) -> <<>>.

val(V) when is_binary(V) -> V;
val(V) -> unicode:characters_to_binary(io_lib:format("~0tp", [V])).

day_text({_, M, D} = Date) ->
    W = lists:nth(calendar:day_of_the_week(Date), ?WEEKDAY),
    unicode:characters_to_binary(io_lib:format("~ts ~2..0B/~2..0B", [W, D, M])).

to_date(D) when is_binary(D) ->
    [Y, M, Dd] = [binary_to_integer(X) || X <- binary:split(D, <<"-">>, [global])],
    {Y, M, Dd};
to_date({_, _, _} = D) -> D.

minutes(T) when is_binary(T) ->
    [H, M] = [binary_to_integer(X) || X <- binary:split(T, <<":">>)],
    H * 60 + M.

holidays() ->
    case ana_db:rows("SELECT day FROM scheduler.holiday WHERE day >= current_date - 60", []) of
        {ok, Rows} -> [to_date(D) || #{<<"day">> := D} <- Rows];
        _ -> []
    end.

%% ---------------------------------------------------------------- the person's side

-spec mine(binary()) -> {ok, [map()]}.
mine(Who) ->
    ana_db:rows("SELECT id, kind, program, title, explanation, payload, created_at FROM automation.suggestion "
                "WHERE username = $1 AND status = 'new' ORDER BY id DESC LIMIT 20", [Who]).

%% Accepting does it at once: the variant (and, for a schedule, the schedule with that variant, as the person, Monday
%% to Friday at that time). Returns what was created, for the screen to open it.
-spec accept(integer(), map(), map()) -> {ok, map()} | {error, integer(), binary(), binary()}.
accept(Id, B, User = #{username := Who}) ->
    case ana_db:one("SELECT * FROM automation.suggestion WHERE id = $1 AND username = $2", [Id, Who]) of
        {ok, #{<<"status">> := <<"new">>, <<"kind">> := Kind, <<"program">> := P, <<"payload">> := Pay}} ->
            Name = case maps:get(<<"name">>, B, null) of
                N when is_binary(N), N =/= <<>> -> N;
                _ -> case Kind of
                         <<"schedule">> -> <<"Agendada às "/utf8, (maps:get(<<"at">>, Pay))/binary>>;
                         _ -> <<"Meus valores"/utf8>>
                     end
            end,
            Entries = maps:map(fun(_, V) -> #{<<"value">> => V} end, maps:get(<<"params">>, Pay, #{})),
            Variant = case maps:size(Entries) of
                0 -> {ok, null};
                _ ->
                    case ana_variants:save(P, #{<<"name">> => Name, <<"entries">> => Entries}, User) of
                        {ok, #{id := V}} -> {ok, V};
                        {error, C, M} -> {error, 400, C, M}
                    end
            end,
            case Variant of
                {error, _, _, _} = E -> E;
                {ok, VId} ->
                    Created = case Kind of
                        <<"variant">> -> {ok, #{<<"variant">> => VId}};
                        <<"schedule">> -> schedule(P, VId, Pay, Name, User)
                    end,
                    case Created of
                        {ok, Res} ->
                            {ok, _} = ana_db:exec("UPDATE automation.suggestion SET status = 'accepted', decided_at = now(), "
                                                  "result = $2 WHERE id = $1", [Id, Res]),
                            {ok, Res};
                        E -> E
                    end
            end;
        {ok, #{}} -> {error, 409, <<"INVALID_STATE">>, <<"esta sugestão já foi respondida"/utf8>>};
        _ -> {error, 404, <<"NOT_FOUND">>, <<"sugestão não encontrada"/utf8>>}
    end.

schedule(P, VId, #{<<"cron">> := Cron} = Pay, Name, User = #{username := Who}) ->
    JobName = iolist_to_binary(["sugestao.", slug(Who), ".", slug(P), ".", integer_to_binary(erlang:unique_integer([positive]) rem 100000)]),
    Fields = #{<<"name">> => binary:part(JobName, 0, min(63, byte_size(JobName))),
               <<"description">> => <<"Sugestão aceita: "/utf8, Name/binary>>,
               <<"program">> => P, <<"params">> => case VId of null -> maps:get(<<"params">>, Pay, #{}); _ -> #{} end,
               <<"variant_id">> => VId, <<"run_as">> => Who, <<"owner">> => Who,
               <<"timezone">> => list_to_binary(ana_config:timezone()),
               <<"triggers">> => [#{<<"kind">> => <<"cron">>, <<"cron">> => Cron}]},
    case ana_schedule:save_job(new, Fields, User) of
        {ok, #{<<"id">> := J}} -> {ok, #{<<"variant">> => VId, <<"job">> => J, <<"cron">> => Cron}};
        {error, M} when is_binary(M) -> {error, 400, <<"INVALID">>, M};
        {error, E} -> {error, 400, <<"INVALID">>, iolist_to_binary(io_lib:format("~0p", [E]))}
    end.

slug(B) ->
    re:replace(string:lowercase(B), <<"[^a-z0-9]+">>, <<"_">>, [global, {return, binary}]).

%% Declined, it never comes back (the fingerprint stays).
-spec decline(integer(), map()) -> {ok, map()} | {error, integer(), binary(), binary()}.
decline(Id, #{username := Who}) ->
    case ana_db:exec("UPDATE automation.suggestion SET status = 'declined', decided_at = now() "
                     "WHERE id = $1 AND username = $2 AND status = 'new'", [Id, Who]) of
        {ok, 1} -> {ok, #{<<"declined">> => true}};
        _ -> {error, 404, <<"NOT_FOUND">>, <<"sugestão não encontrada ou já respondida"/utf8>>}
    end.
