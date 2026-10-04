-- 007 — Execution governance: fine-grained limits, quotas, measurement (spec 012)

ALTER TABLE ana_system.program
    ADD COLUMN limits jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(limits) = 'object');

-- RF-012-04: limits per role or per access group
CREATE TABLE ana_system.limit_profile (
    target_kind text NOT NULL CHECK (target_kind IN ('role', 'group')),
    target      text NOT NULL,
    limits      jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(limits) = 'object'),
    PRIMARY KEY (target_kind, target)
);

-- RF-012-05: per-user exceptions to the global quotas
CREATE TABLE ana_system.user_quota (
    username        text PRIMARY KEY REFERENCES ana_system.app_user(username) ON DELETE CASCADE ON UPDATE CASCADE,
    max_concurrent  integer CHECK (max_concurrent >= 0),
    runs_per_minute integer CHECK (runs_per_minute >= 0)
);

-- RF-012-07: measurement of every execution
ALTER TABLE ana_system.execution
    ADD COLUMN cpu_ms integer,
    ADD COLUMN max_rss_kb integer,
    ADD COLUMN sql_count integer,
    ADD COLUMN rows_read bigint,
    ADD COLUMN limits jsonb;
CREATE INDEX execution_cpu_idx ON ana_system.execution (started_at DESC, cpu_ms);
