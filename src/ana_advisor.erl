%% Optimization advice (spec 019, RF-019-07, 07b, 07c).
%%
%% Runs every 15 min on the scheduler leader (once per cluster) and on demand.
%% Each rule yields findings {rule, target, severity, title, detail, suggestion,
%% evidence}; unchanged advice is not rewritten (P15) and advice that no longer
%% applies is marked resolved. Dismissed advice stays quiet until its date.
-module(ana_advisor).
-behaviour(gen_server).

-export([start_link/0, run/0, upsert/7, list/1, dismiss/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(EVERY_MS, 15 * 60 * 1000).
-define(RULES, [<<"slow_seq_scan">>, <<"growth_risk">>, <<"lint">>, <<"fk_without_index">>, <<"unused_index">>,
                <<"bloat">>, <<"near_limit">>, <<"recurring_timeouts">>]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% On demand (Administração → Dicas → Analisar agora).
-spec run() -> {ok, map()}.
run() -> gen_server:call(?MODULE, run, 120000).

init([]) ->
    erlang:send_after(60000, self(), tick),
    {ok, #{}}.

handle_call(run, _From, S) -> {reply, analyze(), S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(tick, S) ->
    erlang:send_after(?EVERY_MS, self(), tick),
    _ = case catch ana_scheduler:status() of
        #{leader := true} -> catch analyze();
        _ -> ok
    end,
    {noreply, S};
handle_info(_, S) -> {noreply, S}.

%% ---------------------------------------------------------------- engine

analyze() ->
    _ = ana_db:exec("INSERT INTO ana_system.table_growth (day, table_name, rows, bytes) "
                    "SELECT current_date, schemaname || '.' || relname, n_live_tup, pg_total_relation_size(relid) "
                    "FROM pg_stat_user_tables ON CONFLICT DO NOTHING", []),
    Growth = growth(),
    Found = lists:append([safe(fun() -> sql_rules(Growth) end), safe(fun() -> lint_rules(Growth) end),
                          safe(fun fk_rule/0), safe(fun unused_index_rule/0), safe(fun bloat_rule/0),
                          safe(fun near_limit_rule/0), safe(fun timeouts_rule/0)]),
    _ = [upsert(R, T, Sev, Ti, D, Su, E) || {R, T, Sev, Ti, D, Su, E} <- Found],
    Keys = [<<R/binary, "|", T/binary>> || {R, T, _, _, _, _, _} <- Found],
    {ok, Resolved} = ana_db:exec(
        "UPDATE ana_system.advice SET status = 'resolved' WHERE status = 'open' AND rule = ANY($1::text[]) "
        "AND NOT (rule || '|' || target = ANY($2::text[]))", [?RULES, Keys]),
    _ = ana_db:exec("UPDATE ana_system.advice SET status = 'resolved' WHERE status = 'open' AND rule = 'n_plus_one' "
                    "AND last_seen < now() - interval '7 days'", []),
    {ok, #{found => length(Found), resolved => Resolved}}.

safe(F) ->
    try F()
    catch C:R:St -> logger:warning("advisor rule failed: ~0p:~0p ~0p", [C, R, St]), []
    end.

-spec upsert(binary(), binary(), binary(), binary(), binary(), binary(), map()) -> ok.
upsert(Rule, Target, Severity, Title, Detail, Suggestion, Evidence) ->
    _ = ana_db:exec(
        "INSERT INTO ana_system.advice AS a (rule, target, severity, title, detail, suggestion, evidence) "
        "VALUES ($1, $2, $3, $4, $5, $6, $7) "
        "ON CONFLICT (rule, target) DO UPDATE SET severity = EXCLUDED.severity, title = EXCLUDED.title, "
        "  detail = EXCLUDED.detail, suggestion = EXCLUDED.suggestion, evidence = EXCLUDED.evidence, last_seen = now(), "
        "  status = CASE WHEN a.status = 'dismissed' AND (a.dismissed_until IS NULL OR a.dismissed_until > now()) "
        "                THEN 'dismissed' ELSE 'open' END "
        "WHERE a.status = 'resolved' OR (a.status = 'dismissed' AND a.dismissed_until <= now()) "
        "   OR (a.severity, a.title, a.detail, a.suggestion) IS DISTINCT FROM "
        "      (EXCLUDED.severity, EXCLUDED.title, EXCLUDED.detail, EXCLUDED.suggestion) "
        "   OR a.last_seen < now() - interval '1 day'",
        [Rule, Target, Severity, Title, Detail, Suggestion, Evidence]),
    ok.

list(F) ->
    ana_db:rows(
        "SELECT id, rule, target, severity, title, detail, suggestion, evidence, status, dismissed_until, "
        "  first_seen, last_seen FROM ana_system.advice "
        "WHERE ($1::text IS NULL OR status = $1) "
        "ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'serious' THEN 1 WHEN 'warning' THEN 2 ELSE 3 END, "
        "  last_seen DESC LIMIT 500", [maps:get(status, F, null)]).

dismiss(Id, Days, #{username := Who}) ->
    {ok, N} = ana_db:exec("UPDATE ana_system.advice SET status = 'dismissed', dismissed_by = $3, "
                          "dismissed_until = CASE WHEN $2::int > 0 THEN now() + make_interval(days => $2::int) END "
                          "WHERE id = $1", [Id, Days, Who]),
    case N of 1 -> {ok, #{id => Id}}; _ -> {error, not_found} end.

%% ---------------------------------------------------------------- growth (RF-019-07c)

%% #{Table => {Rows, RowsPerDay}} from the daily samples (last 30 days).
growth() ->
    {ok, Rows} = ana_db:rows(
        "SELECT table_name, (array_agg(rows ORDER BY day DESC))[1] AS rows, "
        "  COALESCE(regr_slope(rows, day - current_date), 0)::float8 AS slope "
        "FROM ana_system.table_growth g WHERE day > current_date - 30 GROUP BY table_name", []),
    maps:from_list([{T, {R, S}} || #{<<"table_name">> := T, <<"rows">> := R, <<"slope">> := S} <- Rows, R =/= null]).

projected(Growth, Table, Days) ->
    case maps:get(Table, Growth, undefined) of
        {Rows, Slope} when Slope > 0 -> {Rows, round(Rows + Slope * Days), Slope};
        {Rows, Slope} -> {Rows, Rows, Slope};
        undefined -> undefined
    end.

%% ---------------------------------------------------------------- rules

ms(X) when is_number(X) -> X;
ms(X) when is_binary(X) -> binary_to_float_safe(X);
ms(_) -> 0.

binary_to_float_safe(B) ->
    try binary_to_float(B) catch _:_ -> try float(binary_to_integer(B)) catch _:_ -> 0.0 end end.

fmt(Fmt, Args) -> unicode:characters_to_binary(io_lib:format(Fmt, Args)).

sql_rules(Growth) ->
    Slow = ana_settings:get(slow_sql_ms),
    {ok, Stats} = ana_db:rows(
        "SELECT hash, sql, calls, total_ms, max_ms, (total_ms / GREATEST(calls, 1))::float8 AS mean_ms, programs, plan_summary "
        "FROM ana_system.sql_stat WHERE plan_summary IS NOT NULL AND last_seen > now() - interval '7 days'", []),
    lists:append([sql_findings(S, Slow, Growth) || S <- Stats]).

sql_findings(#{<<"hash">> := H, <<"sql">> := Sql, <<"mean_ms">> := Mean0, <<"max_ms">> := Max0,
               <<"calls">> := Calls, <<"programs">> := Progs, <<"plan_summary">> := Sum}, Slow, Growth) ->
    Mean = ms(Mean0), Max = ms(Max0),
    lists:append([begin
        Table = maps:get(<<"table">>, Scan),
        Rows = case maps:get(<<"table_rows">>, Scan, null) of null -> 0; R -> R end,
        Cols = maps:get(<<"columns">>, Scan, []),
        Index = index_ddl(Table, Cols),
        Ev = #{hash => H, sql => Sql, calls => Calls, mean_ms => Mean, max_ms => Max, table => Table,
               table_rows => Rows, filter => maps:get(<<"filter">>, Scan, null), programs => Progs},
        SlowF = case Rows >= 10000 andalso (Mean >= Slow orelse Max >= Slow * 5) of
            true ->
                [{<<"slow_seq_scan">>, <<H/binary, ":", Table/binary>>, <<"serious">>,
                  fmt("Consulta lenta lê a tabela ~ts inteira (~b linhas)", [Table, Rows]),
                  fmt("Média ~.1f ms, máximo ~.1f ms em ~b chamada(s); o plano faz varredura sequencial.", [Mean, Max, Calls]),
                  Index, Ev}];
            false -> []
        end,
        GrowthF = case projected(Growth, Table, 180) of
            {Now, In180, Slope} when Slope > 0, Now > 0, SlowF =:= [] ->
                Future = Mean * In180 / max(Now, 1),
                case Future >= Slow andalso In180 >= 10000 of
                    true ->
                        [{<<"growth_risk">>, <<H/binary, ":", Table/binary>>, <<"warning">>,
                          fmt("Consulta vai ficar lenta com o crescimento de ~ts", [Table]),
                          fmt("Hoje ~b linhas e ~.1f ms; cresce ~b linhas/dia → ~b linhas e ~~~b ms em 6 meses "
                              "(varredura completa cresce junto com a tabela).", [Now, Mean, round(Slope), In180, round(Future)]),
                          Index, Ev#{projected_rows_180d => In180, projected_ms_180d => Future, rows_per_day => Slope}}];
                    false -> []
                end;
            _ -> []
        end,
        SlowF ++ GrowthF
     end || Scan <- maps:get(<<"seq_scans">>, Sum, []), is_binary(maps:get(<<"table">>, Scan, null))]);
sql_findings(_, _, _) -> [].

index_ddl(Table, []) ->
    fmt("Veja quais colunas o filtro usa e crie um índice nelas (CREATE INDEX CONCURRENTLY … ON ~ts (…)).", [Table]);
index_ddl(Table, Cols) ->
    Name = binary:replace(<<(lists:last(binary:split(Table, <<".">>)))/binary, "_",
                            (iolist_to_binary(lists:join("_", Cols)))/binary, "_idx">>, <<" ">>, <<>>, [global]),
    fmt("CREATE INDEX CONCURRENTLY ~ts ON ~ts (~ts);", [Name, Table, lists:join(", ", Cols)]).

%% Static findings of the programs (RF-019-07b): warnings and above become advice; an
%% "info" finding on a table that is (or will be) large is raised to a warning.
lint_rules(Growth) ->
    {ok, Progs} = ana_db:rows("SELECT name, lint FROM ana_system.program WHERE active AND lint IS NOT NULL "
                              "AND jsonb_array_length(lint) > 0", []),
    lists:append([[F || F <- [lint_finding(Name, L, Growth) || L <- Lint], F =/= none]
                  || #{<<"name">> := Name, <<"lint">> := Lint} <- Progs]).

lint_finding(Name, #{<<"rule">> := Rule, <<"severity">> := Sev, <<"line">> := Line, <<"message">> := Msg} = L, Growth) ->
    Tables = maps:get(<<"tables">>, L, []),
    Big = [{T, Now, In180} || T <- Tables, {Now, In180, _} <- [projected(Growth, T, 180)], In180 >= 100000],
    Severity = case {Sev, Big} of
        {<<"info">>, []} -> none;
        {<<"info">>, _} -> <<"warning">>;
        _ -> Sev
    end,
    case Severity of
        none -> none;
        _ ->
            Extra = case Big of
                [] -> <<>>;
                _ -> iolist_to_binary([" Tabela(s) grande(s) ou crescendo: ",
                                       lists:join(", ", [fmt("~ts (~b → ~b linhas em 6 meses)", [T, N, F]) || {T, N, F} <- Big]),
                                       "."])
            end,
            {<<"lint">>, fmt("~ts:~b:~ts", [Name, Line, Rule]), Severity,
             fmt("~ts, linha ~b: ~ts", [Name, Line, Msg]), <<Msg/binary, Extra/binary>>,
             maps:get(<<"suggestion">>, L, <<>>), L#{<<"program">> => Name}}
    end;
lint_finding(_, _, _) -> none.

fk_rule() ->
    {ok, Rows} = ana_db:rows(
        "SELECT c.conrelid::regclass::text AS tbl, a.attname AS col, c.conname, "
        "  GREATEST(cl.reltuples, 0)::bigint AS rows "
        "FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1] "
        "JOIN pg_class cl ON cl.oid = c.conrelid "
        "WHERE c.contype = 'f' AND array_length(c.conkey, 1) = 1 AND cl.reltuples >= 1000 "
        "  AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.conrelid AND i.indkey[0] = c.conkey[1])", []),
    [{<<"fk_without_index">>, <<T/binary, ".", C/binary>>, <<"info">>,
      fmt("Chave estrangeira sem índice: ~ts.~ts", [T, C]),
      fmt("~b linhas; junções por essa coluna e exclusões na tabela referenciada leem a tabela inteira.", [R]),
      fmt("CREATE INDEX CONCURRENTLY ON ~ts (~ts);", [T, C]), #{constraint => N, rows => R}}
     || #{<<"tbl">> := T, <<"col">> := C, <<"conname">> := N, <<"rows">> := R} <- Rows].

unused_index_rule() ->
    {ok, Rows} = ana_db:rows(
        "SELECT s.schemaname || '.' || s.indexrelname AS idx, s.schemaname || '.' || s.relname AS tbl, "
        "  pg_relation_size(s.indexrelid) AS bytes "
        "FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid "
        "WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary "
        "  AND pg_relation_size(s.indexrelid) > 1048576", []),
    [{<<"unused_index">>, I, <<"info">>, fmt("Índice nunca usado: ~ts", [I]),
      fmt("Ocupa ~b KB em ~ts e custa em cada gravação (contagem desde o último reinício das estatísticas).", [B div 1024, T]),
      fmt("Avalie remover: DROP INDEX CONCURRENTLY ~ts;", [I]), #{table => T, bytes => B}}
     || #{<<"idx">> := I, <<"tbl">> := T, <<"bytes">> := B} <- Rows].

bloat_rule() ->
    {ok, Rows} = ana_db:rows(
        "SELECT schemaname || '.' || relname AS tbl, n_live_tup, n_dead_tup FROM pg_stat_user_tables "
        "WHERE n_dead_tup > 10000 AND n_dead_tup > 0.2 * (n_live_tup + n_dead_tup)", []),
    [{<<"bloat">>, T, <<"warning">>, fmt("Tabela com muito espaço morto: ~ts", [T]),
      fmt("~b linhas mortas para ~b vivas: leituras e índices ficam maiores do que precisam.", [D, L]),
      fmt("VACUUM (ANALYZE) ~ts; e verifique se o autovacuum está acompanhando.", [T]), #{live => L, dead => D}}
     || #{<<"tbl">> := T, <<"n_live_tup">> := L, <<"n_dead_tup">> := D} <- Rows].

near_limit_rule() ->
    {ok, Rows} = ana_db:rows(
        "SELECT program, percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms)::float8 AS p95, "
        "  avg((limits->>'timeout_ms')::numeric)::float8 AS lim, count(*) AS n "
        "FROM ana_system.execution e WHERE started_at > now() - interval '7 days' AND status = 'success' "
        "  AND limits ? 'timeout_ms' AND duration_ms IS NOT NULL "
        "  AND EXISTS (SELECT 1 FROM ana_system.program p WHERE p.name = e.program AND p.active) "
        "GROUP BY program HAVING count(*) >= 5", []),
    [{<<"near_limit">>, P, <<"warning">>, fmt("~ts está perto do limite de tempo", [P]),
      fmt("95% das execuções terminam em até ~b ms; o limite é ~b ms (~b execuções em 7 dias).", [round(P95), round(Lim), N]),
      <<"Otimize o programa (veja Desempenho do SQL e o perfil) ou ajuste o limite em Propriedades e limites."/utf8>>,
      #{p95_ms => P95, limit_ms => Lim, runs => N}}
     || #{<<"program">> := P, <<"p95">> := P95, <<"lim">> := Lim, <<"n">> := N} <- Rows,
        is_number(P95), is_number(Lim), Lim > 0, P95 > 0.8 * Lim].

timeouts_rule() ->
    {ok, Rows} = ana_db:rows(
        "SELECT program, count(*) AS n FROM ana_system.execution e WHERE started_at > now() - interval '7 days' "
        "AND status = 'timeout' AND EXISTS (SELECT 1 FROM ana_system.program p WHERE p.name = e.program AND p.active) "
        "GROUP BY program HAVING count(*) >= 3", []),
    [{<<"recurring_timeouts">>, P, <<"serious">>, fmt("~ts estoura o prazo com frequência", [P]),
      fmt("~b execução(ões) interrompida(s) por tempo nos últimos 7 dias.", [N]),
      <<"Veja o rastro de uma execução lenta (Auditoria → Execuções) para achar o trecho demorado."/utf8>>, #{count => N}}
     || #{<<"program">> := P, <<"n">> := N} <- Rows].
