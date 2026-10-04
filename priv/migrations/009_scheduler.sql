-- 009 — Routine scheduler (spec 018)
-- Internal schema: no privileges for ana_exec/ana_read.

CREATE SCHEMA IF NOT EXISTS scheduler;
REVOKE ALL ON SCHEMA scheduler FROM PUBLIC;

CREATE TABLE scheduler.job (
    id              serial PRIMARY KEY,
    name            text NOT NULL UNIQUE CHECK (name ~ '^[a-z][a-z0-9_.-]{1,62}$'),
    description     text NOT NULL DEFAULT '',
    program         text NOT NULL REFERENCES ana_system.program(name) ON UPDATE CASCADE,
    params          jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(params) = 'object'),
    run_as          text NOT NULL REFERENCES ana_system.app_user(username) ON UPDATE CASCADE,
    limits          jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(limits) = 'object'),
    active          boolean NOT NULL DEFAULT true,
    concurrency     text NOT NULL DEFAULT 'skip' CHECK (concurrency IN ('skip', 'queue', 'parallel')),
    max_parallel    integer NOT NULL DEFAULT 1 CHECK (max_parallel BETWEEN 1 AND 100),
    missed          text NOT NULL DEFAULT 'run_once' CHECK (missed IN ('skip', 'run_once', 'run_all')),
    max_catchup     integer NOT NULL DEFAULT 10 CHECK (max_catchup BETWEEN 1 AND 1000),
    retries         integer NOT NULL DEFAULT 0 CHECK (retries BETWEEN 0 AND 20),
    retry_backoff_s integer NOT NULL DEFAULT 60 CHECK (retry_backoff_s BETWEEN 1 AND 86400),
    on_exhausted    text NOT NULL DEFAULT 'notify' CHECK (on_exhausted IN ('notify', 'pause')),
    window_start    time,
    window_end      time,
    timezone        text NOT NULL DEFAULT 'UTC',
    late_after_s    integer NOT NULL DEFAULT 300 CHECK (late_after_s >= 10),
    notify_program  text REFERENCES ana_system.program(name) ON UPDATE CASCADE ON DELETE SET NULL,
    owner           text NOT NULL,
    created_by      text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CHECK ((window_start IS NULL) = (window_end IS NULL))
);
CREATE INDEX job_program_idx ON scheduler.job (program);
CREATE INDEX job_run_as_idx ON scheduler.job (run_as);
CREATE INDEX job_notify_program_idx ON scheduler.job (notify_program);

CREATE TABLE scheduler.trigger (
    id                 serial PRIMARY KEY,
    job_id             integer NOT NULL REFERENCES scheduler.job(id) ON DELETE CASCADE,
    kind               text NOT NULL CHECK (kind IN ('cron', 'interval', 'once', 'calendar', 'after_job')),
    cron               text,
    interval_s         integer CHECK (interval_s >= 1),
    fire_at            timestamptz,
    rule               text CHECK (rule IN ('last_business_day', 'nth_business_day')),
    nth                integer CHECK (nth BETWEEN 1 AND 23),
    at_time            time,
    after_job_id       integer REFERENCES scheduler.job(id) ON DELETE CASCADE,
    after_condition    text CHECK (after_condition IN ('success', 'failure', 'always')),
    result_param       text CHECK (result_param ~ '^[a-z_][a-z0-9_]*$'),
    business_days_only boolean NOT NULL DEFAULT false,
    starts_at          timestamptz,
    ends_at            timestamptz,
    next_at            timestamptz,
    last_at            timestamptz,
    CHECK (kind <> 'cron' OR cron IS NOT NULL),
    CHECK (kind <> 'interval' OR interval_s IS NOT NULL),
    CHECK (kind <> 'once' OR fire_at IS NOT NULL),
    CHECK (kind <> 'calendar' OR (rule IS NOT NULL AND at_time IS NOT NULL)),
    CHECK (kind <> 'calendar' OR rule <> 'nth_business_day' OR nth IS NOT NULL),
    CHECK (kind <> 'after_job' OR (after_job_id IS NOT NULL AND after_condition IS NOT NULL))
);
CREATE INDEX trigger_job_idx ON scheduler.trigger (job_id);
CREATE INDEX trigger_after_job_idx ON scheduler.trigger (after_job_id);
CREATE INDEX trigger_next_idx ON scheduler.trigger (next_at) WHERE next_at IS NOT NULL;

CREATE TABLE scheduler.holiday (
    day         date PRIMARY KEY,
    description text NOT NULL DEFAULT ''
);

CREATE TABLE scheduler.occurrence (
    id           bigserial PRIMARY KEY,
    job_id       integer NOT NULL REFERENCES scheduler.job(id) ON DELETE CASCADE,
    trigger_id   integer REFERENCES scheduler.trigger(id) ON DELETE SET NULL,
    scheduled_at timestamptz NOT NULL,
    attempt      integer NOT NULL DEFAULT 1,
    status       text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'running', 'success', 'error', 'skipped', 'cancelled')),
    run_after    timestamptz NOT NULL DEFAULT now(),
    params       jsonb,
    execution_id uuid,
    node         text,
    started_at   timestamptz,
    finished_at  timestamptz,
    result       jsonb,
    error        jsonb,
    reason       text,
    late_notified boolean NOT NULL DEFAULT false,
    UNIQUE (job_id, scheduled_at, attempt)          -- RNF-018-01: atomic reservation
);
CREATE INDEX occurrence_pending_idx ON scheduler.occurrence (run_after) WHERE status = 'pending';
CREATE INDEX occurrence_running_idx ON scheduler.occurrence (job_id) WHERE status = 'running';
CREATE INDEX occurrence_trigger_idx ON scheduler.occurrence (trigger_id);
CREATE INDEX occurrence_job_time_idx ON scheduler.occurrence (job_id, scheduled_at DESC);

CREATE TABLE scheduler.notification (
    id         bigserial PRIMARY KEY,
    job_id     integer NOT NULL REFERENCES scheduler.job(id) ON DELETE CASCADE,
    kind       text NOT NULL CHECK (kind IN ('failure', 'late', 'anomaly', 'paused')),
    message    text NOT NULL,
    occurrence_id bigint REFERENCES scheduler.occurrence(id) ON DELETE SET NULL,
    read       boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notification_job_idx ON scheduler.notification (job_id, created_at DESC);
CREATE INDEX notification_occurrence_idx ON scheduler.notification (occurrence_id);
