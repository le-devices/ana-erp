-- 017 — Observability: SQL performance, traces, advice, health, growth (spec 019)

CREATE TABLE ana_system.execution_trace (
    execution_id uuid PRIMARY KEY,
    program      text NOT NULL,
    started_at   timestamptz NOT NULL DEFAULT now(),
    reason       text NOT NULL CHECK (reason IN ('error', 'slow', 'sample', 'profile')),
    sql_ms       numeric(12,3) NOT NULL DEFAULT 0,
    events       jsonb NOT NULL DEFAULT '[]',
    profile      jsonb
);
CREATE INDEX execution_trace_started_brin ON ana_system.execution_trace USING brin (started_at);
CREATE INDEX execution_trace_program_idx ON ana_system.execution_trace (program, started_at DESC);

CREATE TABLE ana_system.sql_stat (
    hash          text PRIMARY KEY,
    sql           text NOT NULL,
    calls         bigint NOT NULL DEFAULT 0,
    total_ms      numeric(16,3) NOT NULL DEFAULT 0,
    max_ms        numeric(12,3) NOT NULL DEFAULT 0,
    rows          bigint NOT NULL DEFAULT 0,
    slow_calls    bigint NOT NULL DEFAULT 0,
    programs      text[] NOT NULL DEFAULT '{}',
    first_seen    timestamptz NOT NULL DEFAULT now(),
    last_seen     timestamptz NOT NULL DEFAULT now(),
    plan          jsonb,
    plan_summary  jsonb,
    plan_at       timestamptz
);
CREATE INDEX sql_stat_total_idx ON ana_system.sql_stat (total_ms DESC);
ALTER TABLE ana_system.sql_stat SET (fillfactor = 80);       -- accumulating upserts stay HOT (P15)

CREATE TABLE ana_system.advice (
    id          bigserial PRIMARY KEY,
    rule        text NOT NULL,
    target      text NOT NULL,
    severity    text NOT NULL CHECK (severity IN ('info', 'warning', 'serious', 'critical')),
    title       text NOT NULL,
    detail      text NOT NULL DEFAULT '',
    suggestion  text NOT NULL DEFAULT '',
    evidence    jsonb NOT NULL DEFAULT '{}',
    status      text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'dismissed', 'resolved')),
    dismissed_until timestamptz,
    dismissed_by text,
    first_seen  timestamptz NOT NULL DEFAULT now(),
    last_seen   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (rule, target)
);
CREATE INDEX advice_status_idx ON ana_system.advice (status, severity);

CREATE TABLE ana_system.health_event (
    id        bigserial PRIMARY KEY,
    component text NOT NULL,
    state     text NOT NULL CHECK (state IN ('green', 'yellow', 'red')),
    message   text NOT NULL DEFAULT '',
    node      text NOT NULL,
    at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX health_event_at_brin ON ana_system.health_event USING brin (at);
CREATE INDEX health_event_component_idx ON ana_system.health_event (component, at DESC);

CREATE TABLE ana_system.incident (
    id         bigserial PRIMARY KEY,
    component  text NOT NULL,
    node       text NOT NULL,
    message    text NOT NULL DEFAULT '',
    opened_at  timestamptz NOT NULL DEFAULT now(),
    closed_at  timestamptz
);
CREATE INDEX incident_open_idx ON ana_system.incident (component, node) WHERE closed_at IS NULL;

CREATE TABLE ana_system.table_growth (
    day        date NOT NULL,
    table_name text NOT NULL,
    rows       bigint NOT NULL,
    bytes      bigint NOT NULL,
    PRIMARY KEY (table_name, day)
);

CREATE TABLE ana_system.metric_sample (
    at      timestamptz NOT NULL DEFAULT now(),
    node    text NOT NULL,
    metrics jsonb NOT NULL,
    PRIMARY KEY (at, node)
);

-- RF-019-07b: static findings of the program's SQL, recomputed on save.
ALTER TABLE ana_system.program ADD COLUMN lint jsonb;
