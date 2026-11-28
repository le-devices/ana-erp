-- 091 — Diagnostic console (spec 077, T-077-05, D7; plan §2.3).
--
-- Ready-made diagnostic queries (the product's, fixed SQL with typed parameters, run by the core in a read-only
-- transaction with a short time limit: they see the database's statistics) and the queries the team saves (typed by a
-- person: run as ana_read, read-only, limited, sensitive columns masked — like any free query of the console).
CREATE TABLE technical.diagnostic_query (
    code        text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$'),
    name        text NOT NULL CHECK (length(btrim(name)) BETWEEN 3 AND 120),
    description text NOT NULL DEFAULT '',
    sql         text NOT NULL CHECK (length(sql) BETWEEN 10 AND 20000),
    params      jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(params) = 'array'),   -- [{name, type, label, default}]
    product     boolean NOT NULL DEFAULT false,     -- fixed by the product (run by the core); else saved by the team
    created_by  text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (product OR created_by IS NOT NULL)
);

INSERT INTO technical.diagnostic_query (code, name, description, sql, params, product) VALUES
('locks', 'Travas: quem espera por quem', 'Sessões bloqueadas, quem as bloqueia e há quanto tempo',
 'SELECT w.pid AS waiting_pid, w.usename AS waiting_user, now() - w.query_start AS waiting_for, left(w.query, 200) AS waiting_query,
         b.pid AS blocking_pid, b.usename AS blocking_user, b.state AS blocking_state, left(b.query, 200) AS blocking_query
    FROM pg_stat_activity w JOIN LATERAL unnest(pg_blocking_pids(w.pid)) AS bp(pid) ON true
    JOIN pg_stat_activity b ON b.pid = bp.pid
   ORDER BY waiting_for DESC NULLS LAST', '[]', true),
('long_transactions', 'Transações longas', 'Transações abertas há mais que o tempo informado',
 'SELECT pid, usename, application_name, state, now() - xact_start AS open_for, left(query, 300) AS query
    FROM pg_stat_activity WHERE xact_start IS NOT NULL AND xact_start < now() - make_interval(mins => $1::int)
   ORDER BY xact_start', '[{"name":"minutes","type":"integer","label":"abertas há mais de (minutos)","default":5}]', true),
('bloat', 'Inchaço das tabelas', 'Linhas mortas por tabela e a última limpeza automática',
 'SELECT schemaname || ''.'' || relname AS table_name, n_live_tup AS live_rows, n_dead_tup AS dead_rows,
         round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct, last_autovacuum, last_autoanalyze
    FROM pg_stat_user_tables WHERE n_dead_tup > 0 ORDER BY n_dead_tup DESC LIMIT 50', '[]', true),
('replicas', 'Réplicas', 'Réplicas ligadas ao primário e o atraso de cada uma',
 'SELECT application_name, client_addr::text AS address, state, sync_state,
         pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes, replay_lag
    FROM pg_stat_replication ORDER BY application_name', '[]', true),
('connections', 'Conexões', 'Conexões abertas por usuário, aplicação e situação',
 'SELECT usename, application_name, state, count(*) AS connections, max(now() - state_change) AS longest_in_state
    FROM pg_stat_activity WHERE backend_type = ''client backend''
   GROUP BY 1, 2, 3 ORDER BY connections DESC', '[]', true),
('largest_tables', 'Maiores tabelas', 'As tabelas que mais ocupam o disco, com índices',
 'SELECT n.nspname || ''.'' || c.relname AS table_name, pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
         pg_size_pretty(pg_relation_size(c.oid)) AS data, pg_size_pretty(pg_indexes_size(c.oid)) AS indexes,
         c.reltuples::bigint AS rows_estimate
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind = ''r'' AND n.nspname NOT IN (''pg_catalog'', ''information_schema'')
   ORDER BY pg_total_relation_size(c.oid) DESC LIMIT $1::int', '[{"name":"limit","type":"integer","label":"quantas","default":20}]', true),
('expensive_queries', 'Consultas mais caras', 'As consultas que mais tempo ocupam no banco (pg_stat_statements, quando ligado)',
 'SELECT left(query, 300) AS query, calls, round(total_exec_time::numeric, 1) AS total_ms,
         round(mean_exec_time::numeric, 2) AS mean_ms, rows
    FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT $1::int',
 '[{"name":"limit","type":"integer","label":"quantas","default":20}]', true);
