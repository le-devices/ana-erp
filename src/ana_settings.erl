%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Runtime settings editable by administrators (spec 011, RF-011-05).
%%
%% Each setting has a type, a range and a default taken from an environment
%% variable (bootstrap). Values saved in ana_system.setting win afterwards.
%% Reads hit an ETS cache (RNF-011-04); changes propagate to every node via
%% NOTIFY "ana_setting" (handled by ana_listener).
-module(ana_settings).
-compile({no_auto_import, [get/1]}).
-export([init_cache/0, load/0, get/1, list/0, set/3, on_notify/2, definitions/0, valid/2]).

-define(TAB, ana_settings_cache).

%% {Key, Type, Min, Max, EnvVar, Default, Description}
definitions() ->
    [{session_hours, integer, 1, 720, "ANA_SESSION_HOURS", 12,
      <<"Validade da sessão de usuário (horas)"/utf8>>},
     {exec_timeout_ms, integer, 1000, 3600000, "ANA_EXEC_TIMEOUT_MS", 60000,
      <<"Tempo máximo de uma execução (ms)"/utf8>>},
     {sql_timeout_ms, integer, 100, 3600000, "ANA_SQL_TIMEOUT_MS", 30000,
      <<"Tempo máximo de um comando SQL de programa (ms)"/utf8>>},
     {lock_timeout_ms, integer, 100, 600000, "ANA_LOCK_TIMEOUT_MS", 10000,
      <<"Espera máxima por travas no banco (ms)"/utf8>>},
     {exec_max, integer, 1, 10000, "ANA_EXEC_MAX", 64,
      <<"Execuções simultâneas permitidas"/utf8>>},
     {debug_max, integer, 0, 100, "ANA_DEBUG_MAX", 8,
      <<"Depurações simultâneas permitidas"/utf8>>},
     {debug_idle_ms, integer, 10000, 86400000, "ANA_DEBUG_IDLE_MS", 600000,
      <<"Ociosidade máxima de uma depuração pausada (ms)"/utf8>>},
     {output_max_kb, integer, 16, 65536, "ANA_OUTPUT_MAX_KB", 512,
      <<"Saída máxima por execução (KiB)"/utf8>>},
     {analytics_interval_s, integer, 10, 86400, "ANA_ANALYTICS_INTERVAL_S", 300,
      <<"Intervalo de atualização analítica (s)"/utf8>>},
     {password_min_length, integer, 8, 128, "ANA_PASSWORD_MIN_LENGTH", 10,
      <<"Tamanho mínimo de senha"/utf8>>},
     {max_login_failures, integer, 3, 100, "ANA_MAX_LOGIN_FAILURES", 5,
      <<"Falhas de login seguidas antes do bloqueio"/utf8>>},
     {lockout_minutes, integer, 1, 1440, "ANA_LOCKOUT_MINUTES", 5,
      <<"Duração do bloqueio por falhas de login (min)"/utf8>>},
     %% Spec 012: defaults and ceilings of per-execution limits (0 = unlimited
     %% for rows, statements and concurrency).
     {default_cpu_ms, integer, 100, 3600000, "ANA_DEFAULT_CPU_MS", 60000,
      <<"CPU padrão por execução (ms)"/utf8>>},
     {default_memory_mb, integer, 32, 65536, "ANA_PY_MEMORY_MB", 512,
      <<"Memória padrão por execução (MiB)"/utf8>>},
     {default_max_rows, integer, 0, 100000000, "ANA_DEFAULT_MAX_ROWS", 0,
      <<"Linhas máximas por consulta, padrão (0 = sem limite)"/utf8>>},
     {default_max_sql, integer, 0, 100000000, "ANA_DEFAULT_MAX_SQL", 0,
      <<"Comandos SQL por execução, padrão (0 = sem limite)"/utf8>>},
     {default_max_concurrent, integer, 0, 100000, "ANA_DEFAULT_MAX_CONCURRENT", 0,
      <<"Execuções simultâneas por programa, padrão (0 = sem limite)"/utf8>>},
     {ceiling_timeout_ms, integer, 1000, 86400000, "ANA_CEILING_TIMEOUT_MS", 600000,
      <<"Teto: tempo de execução (ms)"/utf8>>},
     {ceiling_cpu_ms, integer, 100, 86400000, "ANA_CEILING_CPU_MS", 600000,
      <<"Teto: CPU por execução (ms)"/utf8>>},
     {ceiling_memory_mb, integer, 32, 65536, "ANA_CEILING_MEMORY_MB", 4096,
      <<"Teto: memória por execução (MiB)"/utf8>>},
     {ceiling_sql_timeout_ms, integer, 100, 86400000, "ANA_CEILING_SQL_TIMEOUT_MS", 600000,
      <<"Teto: tempo por comando SQL (ms)"/utf8>>},
     {ceiling_lock_timeout_ms, integer, 100, 3600000, "ANA_CEILING_LOCK_TIMEOUT_MS", 120000,
      <<"Teto: espera por travas (ms)"/utf8>>},
     {ceiling_output_kb, integer, 16, 1048576, "ANA_CEILING_OUTPUT_KB", 65536,
      <<"Teto: saída por execução (KiB)"/utf8>>},
     {ceiling_max_rows, integer, 0, 100000000, "ANA_CEILING_MAX_ROWS", 0,
      <<"Teto: linhas por consulta (0 = sem teto)"/utf8>>},
     {ceiling_max_sql, integer, 0, 100000000, "ANA_CEILING_MAX_SQL", 0,
      <<"Teto: comandos SQL por execução (0 = sem teto)"/utf8>>},
     {ceiling_max_concurrent, integer, 0, 100000, "ANA_CEILING_MAX_CONCURRENT", 0,
      <<"Teto: execuções simultâneas por programa (0 = sem teto)"/utf8>>},
     %% Spec 022: parts running at the same time in one parallel call.
     {default_max_parallel_parts, integer, 1, 1000, "ANA_DEFAULT_MAX_PARALLEL_PARTS", 8,
      <<"Partes paralelas simultâneas por chamada, padrão"/utf8>>},
     {ceiling_max_parallel_parts, integer, 1, 1000, "ANA_CEILING_MAX_PARALLEL_PARTS", 64,
      <<"Teto: partes paralelas simultâneas por chamada"/utf8>>},
     {user_max_concurrent, integer, 0, 100000, "ANA_USER_MAX_CONCURRENT", 16,
      <<"Execuções simultâneas por usuário (0 = sem limite)"/utf8>>},
     {user_runs_per_minute, integer, 0, 1000000, "ANA_USER_RUNS_PER_MINUTE", 600,
      <<"Execuções por minuto por usuário (0 = sem limite)"/utf8>>},
     %% Spec 024: retention policy (days; minimums protect the audit trail).
     {retention_access_days, integer, 1, 36500, "ANA_RETENTION_ACCESS_DAYS", 90,
      <<"Retenção: acessos e comandos SQL (dias)"/utf8>>},
     {retention_login_days, integer, 90, 36500, "ANA_RETENTION_LOGIN_DAYS", 365,
      <<"Retenção: logins (dias, mínimo 90)"/utf8>>},
     {retention_execution_days, integer, 7, 36500, "ANA_RETENTION_EXECUTION_DAYS", 365,
      <<"Retenção: registro das execuções (dias)"/utf8>>},
     {retention_payload_days, integer, 1, 36500, "ANA_RETENTION_PAYLOAD_DAYS", 30,
      <<"Retenção: conteúdo das execuções — parâmetros, resultado, saída, stack traces (dias)"/utf8>>},
     {retention_task_days, integer, 7, 36500, "ANA_RETENTION_TASK_DAYS", 90,
      <<"Retenção: tarefas internas (dias)"/utf8>>},
     {retention_scheduler_days, integer, 7, 36500, "ANA_RETENTION_SCHEDULER_DAYS", 90,
      <<"Retenção: ocorrências e avisos do agendamento (dias)"/utf8>>},
     {retention_admin_log_days, integer, 365, 36500, "ANA_RETENTION_ADMIN_LOG_DAYS", 1825,
      <<"Retenção: alterações administrativas (dias, mínimo 365)"/utf8>>},
     {retention_hour, integer, 0, 23, "ANA_RETENTION_HOUR", 3,
      <<"Hora do expurgo diário (fuso do cliente)"/utf8>>},
     {retention_trace_days, integer, 1, 36500, "ANA_RETENTION_TRACE_DAYS", 30,
      <<"Retenção: rastros de execução e perfis (dias)"/utf8>>},
     {retention_observability_days, integer, 7, 36500, "ANA_RETENTION_OBSERVABILITY_DAYS", 90,
      <<"Retenção: eventos de saúde e amostras de métricas (dias)"/utf8>>},
     {retention_integration_days, integer, 7, 36500, "ANA_RETENTION_INTEGRATION_DAYS", 90,
      <<"Retenção: chamadas e mensagens de integração concluídas (dias)"/utf8>>},
     %% Spec 016.
     {files_max_file_mb, integer, 1, 102400, "ANA_FILES_MAX_FILE_MB", 512,
      <<"Repositório: tamanho máximo de um arquivo (MB)"/utf8>>},
     %% Spec 019: observability.
     {slow_sql_ms, integer, 1, 600000, "ANA_SLOW_SQL_MS", 200,
      <<"Comando SQL lento a partir de (ms): registra o plano e gera dicas"/utf8>>},
     {trace_slow_ms, integer, 1, 3600000, "ANA_TRACE_SLOW_MS", 1000,
      <<"Execução lenta a partir de (ms): sempre guarda o rastro"/utf8>>},
     {trace_sample_pct, integer, 0, 100, "ANA_TRACE_SAMPLE_PCT", 5,
      <<"Rastros guardados das demais execuções (%)"/utf8>>},
     {n_plus_one_threshold, integer, 2, 100000, "ANA_N_PLUS_ONE", 50,
      <<"Mesmo comando SQL repetido numa execução a partir de (vezes): dica N+1"/utf8>>},
     %% Spec 033: periodic checks.
     {checks_backup_max_hours, integer, 1, 8760, "ANA_CHECKS_BACKUP_MAX_HOURS", 26,
      <<"Verificações: idade máxima da cópia completa do banco (horas)"/utf8>>},
     {checks_restore_max_days, integer, 1, 365, "ANA_CHECKS_RESTORE_MAX_DAYS", 35,
      <<"Verificações: idade máxima do último teste de restauração (dias)"/utf8>>},
     {checks_key_max_days, integer, 30, 3650, "ANA_CHECKS_KEY_MAX_DAYS", 365,
      <<"Verificações: idade máxima de chave de API sem validade (dias)"/utf8>>},
     {checks_perf_factor_pct, integer, 110, 1000, "ANA_CHECKS_PERF_FACTOR_PCT", 200,
      <<"Verificações: piora de desempenho a partir de (% da linha de base)"/utf8>>},
     %% Spec 034: development/test instance and transports.
     {transport_required, integer, 0, 1, "ANA_TRANSPORT_REQUIRED", 0,
      <<"Produção: programas só mudam por pacote de transporte (1 = sim)"/utf8>>},
     {transport_four_eyes, integer, 0, 1, "ANA_TRANSPORT_FOUR_EYES", 0,
      <<"Transporte: quem recebeu o pacote não pode importá-lo (1 = sim)"/utf8>>},
     %% Spec 064: quality gate of programs.
     {quality_gate_level, integer, 0, 3, "ANA_QUALITY_GATE_LEVEL", 2,
      <<"Portão de qualidade: severidade que bloqueia o transporte (0 informação, 1 atenção, 2 sério, 3 crítico)"/utf8>>},
     {quality_gate_required, integer, 0, 1, "ANA_QUALITY_GATE_REQUIRED", 0,
      <<"Portão de qualidade: recusar pacote de programas sem relatório do portão verde (1 = sim)"/utf8>>},
     {quality_exemption_max_days, integer, 1, 365, "ANA_QUALITY_EXEMPTION_MAX_DAYS", 90,
      <<"Portão de qualidade: prazo máximo de uma isenção (dias)"/utf8>>},
     %% Spec 064 (D4, D5): tests of programs and their performance against the previous version.
     {quality_tests_required, integer, 0, 1, "ANA_QUALITY_TESTS_REQUIRED", 0,
      <<"Portão de qualidade: programa que grava precisa de ao menos um teste passando (1 = sim)"/utf8>>},
     {quality_perf_sql_pct, integer, 10, 1000, "ANA_QUALITY_PERF_SQL_PCT", 50,
      <<"Portão de qualidade: piora de comandos SQL de um teste, em relação à versão anterior, que vira achado (%)"/utf8>>},
     {quality_perf_time_pct, integer, 10, 1000, "ANA_QUALITY_PERF_TIME_PCT", 100,
      <<"Portão de qualidade: piora de CPU de um teste (acima de 50 ms), em relação à versão anterior, que vira achado (%)"/utf8>>},
     {outbound_blocked, integer, 0, 1, "ANA_OUTBOUND_BLOCKED", 0,
      <<"Bloquear chamadas a sistemas externos (instância de testes com dados copiados)"/utf8>>},
     {api_breaker_failures, integer, 1, 100000, "ANA_API_BREAKER_FAILURES", 20,
      <<"API pública: falhas técnicas (erro interno, tempo esgotado) em 2 min que suspendem o cliente"/utf8>>},
     {api_breaker_ratio, integer, 1, 100, "ANA_API_BREAKER_RATIO", 50,
      <<"API pública: proporção mínima de falhas nas chamadas do cliente para suspender (%)"/utf8>>},
     {api_breaker_open_s, integer, 10, 86400, "ANA_API_BREAKER_OPEN_S", 120,
      <<"API pública: duração da suspensão do cliente (s)"/utf8>>},
     %% Spec 063 (D3): the endurance of the server SSD, for the wear projection of the "Disco" panel.
     {disk_tbw_tb, integer, 0, 1000000, "ANA_DISK_TBW_TB", 0,
      <<"Disco: resistência do SSD informada pelo fabricante (TBW, em TB; 0 = não informada)"/utf8>>},
     {disk_used_pct, integer, 0, 100, "ANA_DISK_USED_PCT", 0,
      <<"Disco: desgaste já usado do SSD (%), quando o ana-ctl não consegue ler"/utf8>>}].

init_cache() ->
    _ = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
    [ets:insert(?TAB, {K, default(Env, D)}) || {K, _, _, _, Env, D, _} <- definitions()],
    ok.

default(Env, D) -> ana_config:integer(Env, D).

%% Loads saved values over the defaults (startup and after reconnecting).
load() ->
    case ana_db:rows("SELECT key, value FROM ana_system.setting", []) of
        {ok, Rows} ->
            [store(K, V) || #{<<"key">> := K, <<"value">> := V} <- Rows],
            ok;
        {error, E} ->
            logger:warning("could not load settings: ~0p", [E])
    end.

store(KeyBin, Value) ->
    case find(KeyBin) of
        {ok, {K, Type, Min, Max, _, _, _}} ->
            case validate(Type, Min, Max, Value) of
                ok -> ets:insert(?TAB, {K, Value});
                _ -> logger:warning("ignoring invalid saved setting ~s", [KeyBin])
            end;
        error -> ok
    end.

-spec get(atom()) -> term().
get(Key) ->
    case ets:lookup(?TAB, Key) of
        [{_, V}] -> V;
        [] -> {_, _, _, _, Env, D, _} = lists:keyfind(Key, 1, definitions()), default(Env, D)
    end.

list() ->
    [#{key => K, type => T, min => Min, max => Max, value => get(K),
       default => default(Env, D), description => Desc}
     || {K, T, Min, Max, Env, D, Desc} <- definitions()].

%% RNF-011-03: validated on the server; invalid values are refused.
-spec set(binary(), term(), map()) -> ok | {error, term()}.
set(KeyBin, Value, #{username := Who}) ->
    case find(KeyBin) of
        {ok, {K, Type, Min, Max, _, _, _}} ->
            case validate(Type, Min, Max, Value) of
                ok ->
                    Before = get(K),
                    {ok, _} = ana_db:exec(
                        "INSERT INTO ana_system.setting (key, value, updated_by) "
                        "VALUES ($1, $2::text::jsonb, $3) ON CONFLICT (key) DO UPDATE SET "
                        "value = EXCLUDED.value, updated_at = now(), updated_by = EXCLUDED.updated_by",
                        [KeyBin, iolist_to_binary(json:encode(Value)), Who]),
                    ets:insert(?TAB, {K, Value}),
                    _ = ana_db:exec("SELECT pg_notify('ana_setting', $1)", [KeyBin]),
                    ana_admin:log(Who, <<"setting.set">>, KeyBin, Before, Value),
                    ok;
                {error, _} = E -> E
            end;
        error -> {error, unknown_setting}
    end.

%% Spec 034: a transported parameter must exist here and be inside its range.
-spec valid(binary(), term()) -> boolean().
valid(KeyBin, Value) ->
    case find(KeyBin) of
        {ok, {_, Type, Min, Max, _, _, _}} -> validate(Type, Min, Max, Value) =:= ok;
        error -> false
    end.

on_notify(_Channel, all) -> load();
on_notify(_Channel, _Key) -> load().

find(KeyBin) when is_binary(KeyBin) ->
    case [D || D = {K, _, _, _, _, _, _} <- definitions(), atom_to_binary(K) =:= KeyBin] of
        [D] -> {ok, D};
        [] -> error
    end;
find(_) -> error.

validate(integer, Min, Max, V) when is_integer(V), V >= Min, V =< Max -> ok;
validate(integer, Min, Max, _) -> {error, {range, Min, Max}}.
