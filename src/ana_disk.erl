%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Disk endurance (spec 063, T-063-01..03; constitution P15): how much the database writes, who
%% wrote it and how long the disk lasts at this pace.
%%
%% Once a minute the cumulative counters of PostgreSQL are read (WAL, data pages from pg_stat_io,
%% temporary files, checkpoints, rows changed per table) and kept in memory: one hour of minutes.
%% Executions note the rows their write statements changed per table (note_writes/2, an ETS
%% counter — no message, no database), so a jump in writing names the program and the table.
%% Rates for the alert rules are read from ETS. Once an hour one row goes to ana_system.disk_sample
%% for the history and the wear projection — only when the hour wrote something (D2), and only on
%% one node (primary key on the hour). Reading the statistics writes nothing (RNF-063-02).
-module(ana_disk).
-behaviour(gen_server).

-export([start_link/0, note_writes/2, rates/0, culprits/0, culprit_text/0, overview/0, sample_now/0]).
-export([write_table/1, projection/3, suggestions/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, ana_disk_writes).
-define(EVERY_MS, 60000).
-define(KEEP, 61).                       % minutes in memory (one hour and the base)
-define(RATE_MIN, 5).                    % window of the alert rates (minutes)
-define(HOURLY_MIN_BYTES, 1048576).      % an hour that wrote less than this is idle: no row (D2)
-define(MAX_KEYS, 20000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Called by ana_sql_stats with the measured statements of one execution: [{Hash, Sql, Calls, _, _, Rows}].
-spec note_writes(binary(), list()) -> ok.
note_writes(Program, Stats) ->
    try
        _ = [count(Program, T, R) || {H, Sql, _C, _T, _M, R} <- Stats, R > 0, T <- [table_of(H, Sql)], T =/= none],
        ok
    catch error:badarg -> ok                                % table not there yet (startup)
    end.

count(Program, Table, Rows) ->
    Key = {w, Program, Table},
    case ets:info(?TAB, size) < ?MAX_KEYS orelse ets:member(?TAB, Key) of
        true -> ets:update_counter(?TAB, Key, Rows, {Key, 0});
        false -> 0                                          % bounded memory
    end.

table_of(Hash, Sql) ->
    case ets:lookup(?TAB, {t, Hash}) of
        [{_, T}] -> T;
        [] ->
            T = write_table(Sql),
            _ = ets:info(?TAB, size) < ?MAX_KEYS andalso ets:insert(?TAB, {{t, Hash}, T}),
            T
    end.

%% The table a write statement changes, or none for reads.
-spec write_table(binary()) -> binary() | none.
write_table(Sql) ->
    Re = "^\\s*(?:WITH\\b.*?\\)\\s*)?(?:INSERT\\s+INTO|UPDATE|DELETE\\s+FROM|MERGE\\s+INTO|COPY)\\s+(?:ONLY\\s+)?"
         "\"?([A-Za-z_][A-Za-z0-9_]*\"?(?:\\.\"?[A-Za-z_][A-Za-z0-9_]*)?)",
    case re:run(Sql, Re, [caseless, dotall, {capture, [1], binary}]) of
        {match, [T]} -> string:lowercase(binary:replace(T, <<"\"">>, <<>>, [global]));
        nomatch -> none
    end.

%% #{<<"wal_mb_per_hour">>, <<"temp_mb_per_hour">>}: the pace of the last minutes, for the alert rules.
-spec rates() -> map().
rates() ->
    case catch ets:lookup(?TAB, rates) of
        [{rates, R}] -> R;
        _ -> #{}
    end.

%% What wrote most in the rate window: #{tables => [{T, Rows}], programs => [{P, T, Rows}]}.
culprits() ->
    case catch ets:lookup(?TAB, culprits) of
        [{culprits, C}] -> C;
        _ -> #{tables => [], programs => []}
    end.

%% One line for the incident: the tables and the programs responsible (CA-063-04).
-spec culprit_text() -> binary().
culprit_text() ->
    #{tables := Ts, programs := Ps} = culprits(),
    T = [io_lib:format("~ts (~b linhas)", [N, R]) || {N, R} <- lists:sublist(Ts, 3)],
    P = [io_lib:format("~ts em ~ts (~b linhas)", [Pr, N, R]) || {Pr, N, R} <- lists:sublist(Ps, 3)],
    unicode:characters_to_binary(
        [case T of [] -> []; _ -> ["tabelas que mais mudaram: ", lists:join(", ", T)] end,
         case {T, P} of {[], _} -> []; {_, []} -> []; _ -> "; " end,
         case P of [] -> []; _ -> ["programas: ", lists:join(", ", P)] end]).

sample_now() -> gen_server:call(?MODULE, sample, 30000).

%% Years left for a disk of Tbw terabytes written, UsedPct already worn, writing BytesPerDay.
-spec projection(number(), number(), number()) -> map().
projection(Tbw, _UsedPct, _PerDay) when Tbw =< 0 -> #{informed => false};
projection(Tbw, UsedPct, PerDay) ->
    Left = max(0.0, Tbw * 1.0e12 * (1 - min(UsedPct, 100) / 100)),
    Years = case PerDay > 0 of true -> Left / PerDay / 365.0; false -> null end,
    #{informed => true, tbw_tb => Tbw, used_pct => UsedPct, left_bytes => round(Left), bytes_per_day => round(PerDay),
      years_left => case Years of null -> null; Y -> round(Y * 10) / 10 end}.

%% The "Disco" panel (D3).
overview() -> gen_server:call(?MODULE, overview, 30000).

%% ---------------------------------------------------------------- server

init([]) ->
    _ = ets:new(?TAB, [named_table, public, set, {write_concurrency, true}, {read_concurrency, true}]),
    erlang:send_after(5000, self(), tick),
    {ok, #{samples => [], hour_base => undefined}}.

handle_call(sample, _From, S) ->
    S2 = refresh(S),
    {reply, ok, S2};
handle_call(overview, _From, S) ->
    S2 = refresh(S),
    {reply, catch_overview(S2), S2}.

handle_cast(_, S) -> {noreply, S}.

handle_info(tick, S) ->
    erlang:send_after(?EVERY_MS, self(), tick),
    S2 = try tick(S) catch C:R:St -> logger:warning("disk sample failed: ~0p:~0p ~0p", [C, R, St]), S end,
    {noreply, S2};
handle_info(_, S) -> {noreply, S}.

%% On demand (the panel, the battery): the newest sample is replaced when it is younger than a minute,
%% so refreshing often never shortens the hour kept in memory.
refresh(S = #{samples := [#{at := At} | Old = [_ | _]]}) ->
    case erlang:system_time(second) - At < 60 of
        true -> tick(S#{samples := Old});
        false -> tick(S)
    end;
refresh(S) -> tick(S).

tick(S = #{samples := Old, hour_base := Base}) ->
    case read() of
        {ok, Now} ->
            Samples = lists:sublist([Now | Old], ?KEEP),
            publish(Samples),
            S#{samples := Samples, hour_base := hourly(Base, Now)};
        _ -> S
    end.

%% Cumulative counters of the database cluster, and the rows changed per table and per program.
read() ->
    Sql = ["SELECT (SELECT wal_bytes::bigint FROM pg_stat_wal) AS wal, ", data_sql(), " AS data, "
          "  (SELECT COALESCE(sum(temp_bytes), 0)::bigint FROM pg_stat_database) AS temp, "
          "  (SELECT COALESCE(sum(temp_files), 0)::bigint FROM pg_stat_database) AS temp_files, "
          "  (SELECT checkpoints_timed FROM pg_stat_bgwriter) AS ck_timed, "
          "  (SELECT checkpoints_req FROM pg_stat_bgwriter) AS ck_req, "
          "  (SELECT stats_reset FROM pg_stat_wal) AS reset, "
          "  (SELECT json_object_agg(schemaname || '.' || relname, n_tup_ins + n_tup_upd + n_tup_del) "
          "     FROM pg_stat_user_tables WHERE n_tup_ins + n_tup_upd + n_tup_del > 0)::text AS tables"],
    case ana_db:one(iolist_to_binary(Sql), []) of
        {ok, R = #{<<"wal">> := Wal}} when is_integer(Wal) ->
            Tables = case maps:get(<<"tables">>, R) of null -> #{}; J -> json:decode(J) end,
            Programs = maps:from_list([{{P, T}, N} || {{w, P, T}, N} <- ets:tab2list(?TAB)]),
            {ok, #{at => erlang:system_time(second), wal => Wal, data => maps:get(<<"data">>, R),
                   temp => maps:get(<<"temp">>, R), temp_files => maps:get(<<"temp_files">>, R),
                   ck_timed => maps:get(<<"ck_timed">>, R), ck_req => maps:get(<<"ck_req">>, R),
                   reset => maps:get(<<"reset">>, R), tables => Tables, programs => Programs}};
        {ok, _} -> {error, no_statistics};
        E -> E
    end.

%% Data pages written: pg_stat_io from PostgreSQL 16 on; before it (a managed PostgreSQL 15), the
%% buffers written by the checkpointer, the background writer and the backends.
data_sql() ->
    case has_stat_io() of
        true -> "(SELECT COALESCE(sum(writes * op_bytes), 0)::bigint FROM pg_stat_io WHERE writes > 0)";
        false -> "(SELECT ((buffers_checkpoint + buffers_clean + buffers_backend) * current_setting('block_size')::bigint) "
                 "FROM pg_stat_bgwriter)"
    end.

has_stat_io() ->
    case persistent_term:get({?MODULE, stat_io}, undefined) of
        undefined ->
            case ana_db:one("SELECT current_setting('server_version_num')::int >= 160000 AS v", []) of
                {ok, #{<<"v">> := B}} -> persistent_term:put({?MODULE, stat_io}, B), B;
                _ -> false                                          % asked again next time
            end;
        V -> V
    end.

%% Rates and culprits of the last ?RATE_MIN minutes, for ana_health (read from ETS).
publish([Now | _] = Samples) ->
    case lists:nth(min(length(Samples), ?RATE_MIN + 1), Samples) of
        Now -> ok;
        Then ->
            Secs = max(1, maps:get(at, Now) - maps:get(at, Then)),
            PerHour = fun(K) -> round(max(0, maps:get(K, Now) - maps:get(K, Then)) * 3600 / Secs / 104857.6) / 10 end,
            ets:insert(?TAB, [{rates, #{<<"wal_mb_per_hour">> => PerHour(wal), <<"temp_mb_per_hour">> => PerHour(temp)}},
                              {culprits, #{tables => top(delta(tables, Now, Then)),
                                           programs => [{P, T, N} || {{P, T}, N} <- top(delta(programs, Now, Then))]}}]),
            ok
    end.

delta(K, Now, Then) ->
    B = maps:get(K, Then),
    maps:filter(fun(_, V) -> V > 0 end, maps:map(fun(Key, V) -> V - maps:get(Key, B, 0) end, maps:get(K, Now))).

top(M) -> lists:sublist(lists:reverse(lists:keysort(2, maps:to_list(M))), 10).

%% One row per hour, when the hour wrote something. The base is the first sample of the hour.
hourly(undefined, Now) -> Now;
hourly(Base, Now) ->
    Hour = fun(#{at := At}) -> At div 3600 end,
    case Hour(Now) =:= Hour(Base) of
        true -> Base;
        false ->
            Wal = maps:get(wal, Now) - maps:get(wal, Base),
            _ = (Wal >= ?HOURLY_MIN_BYTES orelse Wal < 0 orelse stale())
                andalso is_pid(spawn(fun() -> store(Hour(Base) * 3600, Base, Now) end)),
            Now
    end.

%% A row at least once a day, so the counters of a long idle period are not lost.
stale() ->
    case ana_db:one("SELECT COALESCE(max(hour) < now() - interval '1 day', true) AS stale FROM ana_system.disk_sample", []) of
        {ok, #{<<"stale">> := true}} -> true;
        _ -> false
    end.

store(HourStart, Base, Now) ->
    Tables = [#{table => T, rows => N} || {T, N} <- top(delta(tables, Now, Base))],
    Programs = [#{program => P, table => T, rows => N} || {{P, T}, N} <- top(delta(programs, Now, Base))],
    _ = ana_db:exec("INSERT INTO ana_system.disk_sample (hour, stats_reset, wal_bytes, data_bytes, temp_bytes, "
                    "  checkpoints_timed, checkpoints_req, top_tables, top_programs) "
                    "VALUES (to_timestamp($1), $2, $3, $4, $5, $6, $7, $8::text::jsonb, $9::text::jsonb) "
                    "ON CONFLICT (hour) DO NOTHING",
                    [HourStart, maps:get(reset, Now), maps:get(wal, Now), maps:get(data, Now), maps:get(temp, Now),
                     maps:get(ck_timed, Now), maps:get(ck_req, Now),
                     iolist_to_binary(json:encode(Tables)), iolist_to_binary(json:encode(Programs))]),
    ok.

%% ---------------------------------------------------------------- panel

catch_overview(S) ->
    try overview(S)
    catch C:R:St ->
        logger:warning("disk overview failed: ~0p:~0p ~0p", [C, R, St]),
        {error, <<"Não foi possível ler as estatísticas de escrita do banco agora; tente de novo em instantes."/utf8>>}
    end.

overview(#{samples := Samples}) ->
    {ok, Hours} = ana_db:rows(
        "SELECT extract(epoch FROM hour)::bigint AS hour, stats_reset, wal_bytes, data_bytes, temp_bytes, "
        "  checkpoints_timed, checkpoints_req, top_tables, top_programs "
        "FROM ana_system.disk_sample WHERE hour > now() - interval '35 days' ORDER BY hour", []),
    {ok, Io} = case has_stat_io() of
        true -> ana_db:rows(
                    "SELECT backend_type, object, context, (writes * op_bytes)::bigint AS write_bytes, "
                    "  (extends * op_bytes)::bigint AS extend_bytes, fsyncs "
                    "FROM pg_stat_io WHERE COALESCE(writes, 0) + COALESCE(extends, 0) > 0 "
                    "ORDER BY COALESCE(writes, 0) DESC", []);
        false -> {ok, []}
    end,
    {ok, [Ck0]} = ana_db:rows(
        "SELECT checkpoints_timed, checkpoints_req, buffers_checkpoint, buffers_clean, buffers_backend, "
        "  (SELECT stats_reset FROM pg_stat_wal) AS since, "
        "  (SELECT wal_bytes::bigint FROM pg_stat_wal) AS wal_bytes, "
        "  (SELECT sum(temp_files)::bigint FROM pg_stat_database) AS temp_files, "
        "  (SELECT sum(temp_bytes)::bigint FROM pg_stat_database) AS temp_bytes, "
        "  current_setting('max_wal_size') AS max_wal_size, current_setting('checkpoint_timeout') AS checkpoint_timeout, "
        "  current_setting('wal_compression') AS wal_compression, current_setting('log_temp_files') AS log_temp_files, "
        "  current_setting('archive_mode') AS archive_mode, current_setting('archive_timeout') AS archive_timeout "
        "FROM pg_stat_bgwriter", []),
    Ck = recent_checkpoints(Ck0),
    {ok, Growth} = ana_db:rows(
        "SELECT table_name, (array_agg(bytes ORDER BY day DESC))[1] AS bytes, "
        "  (array_agg(bytes ORDER BY day DESC))[1] - (array_agg(bytes ORDER BY day))[1] AS growth_bytes, "
        "  max(day) - min(day) AS days "
        "FROM ana_system.table_growth WHERE day > current_date - 30 GROUP BY table_name "
        "ORDER BY 3 DESC NULLS LAST LIMIT 10", []),
    {ok, [Sizes]} = ana_db:rows(
        "SELECT pg_database_size(current_database())::bigint AS database_bytes, "
        "  (SELECT COALESCE(sum(size), 0)::bigint FROM files.blob) AS files_bytes", []),
    Health = disk_health(),
    UsedPct = case Health of #{<<"used_pct">> := U} when is_number(U) -> U; _ -> ana_settings:get(disk_used_pct) end,
    LastHour = last_hour(Samples),
    Days = per_day(Hours, Samples),
    PerDay = avg_per_day(Days),
    {ok, #{last_hour => LastHour, rates => rates(), hours => Hours, days => Days, io => Io, checkpoints => Ck,
           growth => Growth, sizes => Sizes, budget => budget(),
           projection => projection(ana_settings:get(disk_tbw_tb), UsedPct, PerDay), disk_health => Health,
           suggestions => suggestions(Ck)}}.

%% The last reading of the SSD by "ana-ctl doctor" / "ana-ctl disk" (D5), when the server allows it.
disk_health() ->
    case ana_db:one("SELECT detail, at FROM ana_system.ops_event WHERE kind = 'disk_health' AND ok "
                    "ORDER BY at DESC LIMIT 1", []) of
        {ok, #{<<"detail">> := D, <<"at">> := At}} ->
            try (json:decode(D))#{<<"at">> => At} catch _:_ -> null end;
        _ -> null
    end.

%% The last hour in memory (or what there is of it): bytes and the tables and programs that wrote most.
last_hour([]) -> #{minutes => 0};
last_hour([Now | _] = Samples) ->
    Then = lists:last(Samples),
    #{minutes => (maps:get(at, Now) - maps:get(at, Then)) div 60,
      wal_bytes => maps:get(wal, Now) - maps:get(wal, Then),
      data_bytes => maps:get(data, Now) - maps:get(data, Then),
      temp_bytes => maps:get(temp, Now) - maps:get(temp, Then),
      tables => [#{table => T, rows => N} || {T, N} <- top(delta(tables, Now, Then))],
      programs => [#{program => P, table => T, rows => N} || {{P, T}, N} <- top(delta(programs, Now, Then))]}.

%% Bytes written per day (WAL + data pages + temporary) from consecutive hourly rows; a counter reset
%% (a row whose counters went down) starts again from that row.
per_day(Hours, Samples) ->
    Points = [{H, W, D, T} || #{<<"hour">> := H, <<"wal_bytes">> := W, <<"data_bytes">> := D, <<"temp_bytes">> := T} <- Hours]
             ++ [{maps:get(at, N), maps:get(wal, N), maps:get(data, N), maps:get(temp, N)} || N <- lists:sublist(Samples, 1)],
    Pairs = case Points of [_, _ | _] -> lists:zip(lists:droplast(Points), tl(Points)); _ -> [] end,
    Acc = lists:foldl(
        fun({{_, W0, D0, T0}, {H1, W1, D1, T1}}, M) when W1 >= W0, D1 >= D0, T1 >= T0 ->
                Day = calendar:gregorian_days_to_date(H1 div 86400 + 719528),
                {Wa, Da, Ta} = maps:get(Day, M, {0, 0, 0}),
                M#{Day => {Wa + W1 - W0, Da + D1 - D0, Ta + T1 - T0}};
           (_, M) -> M
        end, #{}, Pairs),
    [#{day => iolist_to_binary(io_lib:format("~4..0b-~2..0b-~2..0b", [Y, Mo, D])), wal_bytes => W, data_bytes => Da,
       temp_bytes => T, total_bytes => W + Da + T}
     || {{Y, Mo, D}, {W, Da, T}} <- lists:sort(maps:to_list(Acc))].

%% Average of the complete days (today is still running), or of today when it is all there is.
avg_per_day([]) -> 0;
avg_per_day(Days) ->
    Complete = case length(Days) > 1 of true -> lists:droplast(Days); false -> Days end,
    lists:sum([maps:get(total_bytes, D) || D <- Complete]) / length(Complete).

%% The versioned write budget (D1), the same file the battery tests against.
budget() ->
    File = filename:join(code:priv_dir(ana), "disk_budget.json"),
    case file:read_file(File) of
        {ok, B} -> json:decode(B);
        _ -> null
    end.

archive_short(<<"0">>) -> false;
archive_short(T) ->
    case re:run(T, "^([0-9]+)(s|min)?$", [{capture, all_but_first, binary}]) of
        {match, [N]} -> binary_to_integer(N) < 900;
        {match, [N, <<"s">>]} -> binary_to_integer(N) < 900;
        {match, [N, <<"min">>]} -> binary_to_integer(N) < 15;
        _ -> false
    end.

%% Checkpoints of the last 7 days (finding d of spec 063): the counters run since the statistics
%% were last reset, so a configuration fixed long ago would keep being blamed.
recent_checkpoints(Ck = #{<<"checkpoints_timed">> := T, <<"checkpoints_req">> := R}) ->
    case ana_db:one("SELECT checkpoints_timed, checkpoints_req FROM ana_system.disk_sample "
                    "WHERE hour > now() - interval '7 days' AND checkpoints_timed IS NOT NULL ORDER BY hour LIMIT 1", []) of
        {ok, #{<<"checkpoints_timed">> := T0, <<"checkpoints_req">> := R0}} when T >= T0, R >= R0 ->
            Ck#{<<"recent_timed">> => T - T0, <<"recent_req">> => R - R0, <<"recent_days">> => 7};
        _ -> Ck#{<<"recent_timed">> => T, <<"recent_req">> => R, <<"recent_days">> => null}
    end.

%% Server configuration the ERP suggests and never changes (D5, D6).
suggestions(Ck) ->
    Timed = maps:get(<<"recent_timed">>, Ck),
    Req = maps:get(<<"recent_req">>, Ck),
    [<<"Mais da metade dos checkpoints foi forçada pelo volume de WAL: aumente max_wal_size para espaçá-los."/utf8>>
     || Req > Timed, Req > 10]
    ++ [<<"log_temp_files está desligado: ligue-o (por exemplo 10MB) para saber quais consultas derramam em arquivos temporários."/utf8>>
        || maps:get(<<"log_temp_files">>, Ck) =:= <<"-1">>]
    ++ [<<"Compressão do WAL desligada: use wal_compression = lz4."/utf8>> || maps:get(<<"wal_compression">>, Ck) =:= <<"off">>]
    ++ [<<"O arquivo de WAL troca de segmento a cada "/utf8, (maps:get(<<"archive_timeout">>, Ck))/binary,
          " quando houve qualquer escrita: cada troca copia um segmento inteiro (16 MB). Um intervalo maior grava menos, "
          "ao custo de uma janela maior de perda se o servidor inteiro se perder (as transações confirmadas continuam no disco). "
          "A janela é escolhida na instalação (--archive-minutes, padrão 5) e muda com ana-ctl archive-minutes N (1 a 60)."/utf8>>
        || maps:get(<<"archive_mode">>, Ck) =/= <<"off">>, archive_short(maps:get(<<"archive_timeout">>, Ck))]
    ++ [<<"No servidor: monte o disco com noatime, deixe o TRIM periódico ligado (fstrim.timer), "
          "ponha o WAL num volume próprio quando houver dois discos e guarde as cópias em outro disco."/utf8>>].
