-- 011 — Audit trail and retention policy (spec 024)

-- RF-024-01..03: every API request. No FK on username: failed credentials
-- are recorded too, and writes must stay cheap.
-- RF-025-02: partitioned by day; retention drops whole partitions.
CREATE TABLE ana_system.access_event (
    id           bigserial,
    at           timestamptz NOT NULL DEFAULT now(),
    username     text,
    auth         text NOT NULL CHECK (auth IN ('session', 'api_key', 'password', 'anonymous', 'node')),
    api_key_id   integer,
    ip           text,
    method       text NOT NULL,
    path         text NOT NULL,
    status       smallint,
    duration_ms  integer,
    node         text NOT NULL,
    detail       text,
    PRIMARY KEY (id, at)
) PARTITION BY RANGE (at);
CREATE TABLE ana_system.access_event_default PARTITION OF ana_system.access_event DEFAULT;
CREATE INDEX access_event_at_brin ON ana_system.access_event USING brin (at);
CREATE INDEX access_event_username_idx ON ana_system.access_event (username, at DESC);

-- RF-024-04/05
ALTER TABLE ana_system.execution
    ADD COLUMN client_ip         text,
    ADD COLUMN api_key_id        integer,
    ADD COLUMN node              text,
    ADD COLUMN internal_trace    text,
    ADD COLUMN payload_purged_at timestamptz;
CREATE INDEX execution_started_idx ON ana_system.execution (started_at);
CREATE INDEX execution_payload_idx ON ana_system.execution (started_at) WHERE payload_purged_at IS NULL;

-- RF-024-09: one purge per day in the cluster.
CREATE TABLE ana_system.retention_day (
    day        date PRIMARY KEY,
    node       text NOT NULL,
    claimed_at timestamptz NOT NULL DEFAULT now()
);

-- RF-025-05: the end-of-execution update touches no indexed column (HOT).
-- The consumption ranking by period uses execution_started_idx.
DROP INDEX IF EXISTS ana_system.execution_cpu_idx;
ALTER TABLE ana_system.execution SET (fillfactor = 90);
ALTER TABLE scheduler.occurrence SET (fillfactor = 90);
ALTER TABLE scheduler.trigger SET (fillfactor = 90);
ALTER TABLE ana_system.api_key SET (fillfactor = 90);
