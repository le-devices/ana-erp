-- 063 — Disk endurance (spec 063, T-063-01..03; constitution P15): how much the database writes.
-- One row per hour with the cumulative counters of PostgreSQL (WAL, data pages, temporary files,
-- checkpoints) and what changed most in that hour. Written by one node only (primary key on the
-- hour) and skipped when the hour wrote almost nothing (D2: idle does not write); a gap between
-- two rows is an idle period, recovered from the cumulative counters of the next row.
CREATE TABLE ana_system.disk_sample (
    hour            timestamptz PRIMARY KEY,
    stats_reset     timestamptz,                 -- counters restart at a statistics reset
    wal_bytes       bigint NOT NULL,
    data_bytes      bigint NOT NULL,             -- pg_stat_io: relation pages written by every process
    temp_bytes      bigint NOT NULL,
    checkpoints_timed bigint NOT NULL,
    checkpoints_req bigint NOT NULL,
    top_tables      jsonb NOT NULL DEFAULT '[]', -- [{table, rows}] changed in the hour
    top_programs    jsonb NOT NULL DEFAULT '[]'  -- [{program, table, rows}] written in the hour
);
COMMENT ON TABLE ana_system.disk_sample IS 'Escrita do banco por hora (spec 063): contadores acumulados e o que mais escreveu';
