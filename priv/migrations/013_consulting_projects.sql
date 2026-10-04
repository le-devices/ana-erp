-- 013 — Consulting: client projects end to end (spec 021)

-- ---------------------------------------------------------------- RF-021-01
-- Tasks of spec 008 become the activities; phases are tasks of kind 'phase'.
ALTER TABLE projects.task
    ADD COLUMN kind                text NOT NULL DEFAULT 'activity' CHECK (kind IN ('phase', 'activity')),
    ADD COLUMN parent_id           integer REFERENCES projects.task(id) ON DELETE CASCADE,
    ADD COLUMN seq                 integer NOT NULL DEFAULT 0,
    ADD COLUMN owner_employee_id   integer REFERENCES projects.employee(id),
    ADD COLUMN profile             text REFERENCES projects.rate_profile(code),
    ADD COLUMN duration_days       integer CHECK (duration_days BETWEEN 0 AND 3650),
    ADD COLUMN planned_start       date,
    ADD COLUMN planned_finish      date,
    ADD COLUMN status              text NOT NULL DEFAULT 'todo'
                                   CHECK (status IN ('todo', 'doing', 'review', 'done', 'blocked')),
    ADD COLUMN percent_complete    numeric(5,2) NOT NULL DEFAULT 0 CHECK (percent_complete BETWEEN 0 AND 100),
    ADD COLUMN actual_start        date,
    ADD COLUMN actual_finish       date,
    ADD COLUMN deliverable         text,
    ADD COLUMN acceptance_criteria text,
    ADD COLUMN notes               text,
    ADD COLUMN client_visible      boolean NOT NULL DEFAULT true,
    ADD COLUMN updated_at          timestamptz NOT NULL DEFAULT now(),
    ADD CONSTRAINT task_dates CHECK (planned_finish IS NULL OR planned_start IS NULL OR planned_finish >= planned_start),
    ADD CONSTRAINT task_phase_no_parent CHECK (kind = 'activity' OR parent_id IS NULL);
CREATE INDEX task_parent_idx ON projects.task (parent_id);
CREATE INDEX task_owner_idx ON projects.task (owner_employee_id);
CREATE INDEX task_profile_idx ON projects.task (profile);
ALTER TABLE projects.task SET (fillfactor = 90);       -- progress updates are HOT (P15)

CREATE TABLE projects.task_dependency (
    task_id        integer NOT NULL REFERENCES projects.task(id) ON DELETE CASCADE,
    predecessor_id integer NOT NULL REFERENCES projects.task(id) ON DELETE CASCADE,
    lag_days       integer NOT NULL DEFAULT 0 CHECK (lag_days BETWEEN -365 AND 365),
    PRIMARY KEY (task_id, predecessor_id),
    CHECK (task_id <> predecessor_id)
);
CREATE INDEX task_dependency_predecessor_idx ON projects.task_dependency (predecessor_id);

-- Hours are logged on activities, never on phases.
CREATE FUNCTION projects.time_entry_activity_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM projects.task WHERE id = NEW.task_id AND kind = 'phase') THEN
        RAISE EXCEPTION 'PHASE_NOT_LOGGABLE: horas são apontadas nas atividades, não na fase'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER time_entry_activity_only BEFORE INSERT OR UPDATE OF task_id ON projects.time_entry
    FOR EACH ROW EXECUTE FUNCTION projects.time_entry_activity_only();

-- ---------------------------------------------------------------- RF-021-02
CREATE TABLE projects.template (
    code         text PRIMARY KEY CHECK (code ~ '^[A-Z0-9_-]{1,30}$'),
    name         text NOT NULL,
    service_kind text NOT NULL DEFAULT '',
    description  text NOT NULL DEFAULT '',
    active       boolean NOT NULL DEFAULT true
);

CREATE TABLE projects.template_item (
    template_code   text NOT NULL REFERENCES projects.template(code) ON DELETE CASCADE ON UPDATE CASCADE,
    code            text NOT NULL CHECK (code ~ '^[0-9A-Za-z._-]{1,20}$'),
    seq             integer NOT NULL DEFAULT 0,
    kind            text NOT NULL DEFAULT 'activity' CHECK (kind IN ('phase', 'activity')),
    parent_code     text,
    name            text NOT NULL,
    profile         text REFERENCES projects.rate_profile(code),
    planned_hours   numeric(10,2) CHECK (planned_hours >= 0),
    duration_days   integer CHECK (duration_days BETWEEN 0 AND 3650),
    predecessors    text[] NOT NULL DEFAULT '{}',
    deliverable     text,
    billable        boolean NOT NULL DEFAULT true,
    PRIMARY KEY (template_code, code)
);
CREATE INDEX template_item_profile_idx ON projects.template_item (profile);

-- ---------------------------------------------------------------- RF-021-03
ALTER TABLE projects.employee
    ADD COLUMN weekly_hours numeric(5,2) NOT NULL DEFAULT 40 CHECK (weekly_hours BETWEEN 0 AND 80);

CREATE TABLE projects.absence (
    id          serial PRIMARY KEY,
    employee_id integer NOT NULL REFERENCES projects.employee(id) ON DELETE CASCADE,
    from_date   date NOT NULL,
    to_date     date NOT NULL,
    kind        text NOT NULL DEFAULT 'vacation' CHECK (kind IN ('vacation', 'leave', 'training', 'other')),
    CHECK (to_date >= from_date)
);
CREATE INDEX absence_employee_idx ON projects.absence (employee_id, from_date);

CREATE TABLE projects.allocation (
    id          bigserial PRIMARY KEY,
    project_id  integer NOT NULL REFERENCES projects.project(id) ON DELETE CASCADE,
    task_id     integer NOT NULL REFERENCES projects.task(id) ON DELETE CASCADE,
    week        date NOT NULL CHECK (extract(isodow FROM week) = 1),
    employee_id integer REFERENCES projects.employee(id),
    profile     text REFERENCES projects.rate_profile(code),
    hours       numeric(6,2) NOT NULL CHECK (hours >= 0 AND hours <= 168),
    CHECK ((employee_id IS NULL) <> (profile IS NULL))
);
CREATE UNIQUE INDEX allocation_employee_uk ON projects.allocation (task_id, employee_id, week) WHERE employee_id IS NOT NULL;
CREATE UNIQUE INDEX allocation_profile_uk ON projects.allocation (task_id, profile, week) WHERE profile IS NOT NULL;
CREATE INDEX allocation_employee_week_idx ON projects.allocation (employee_id, week);
CREATE INDEX allocation_project_idx ON projects.allocation (project_id, week);
CREATE INDEX allocation_profile_idx ON projects.allocation (profile);

-- ---------------------------------------------------------------- RF-021-06
CREATE TABLE projects.baseline (
    id            serial PRIMARY KEY,
    project_id    integer NOT NULL REFERENCES projects.project(id) ON DELETE CASCADE,
    number        integer NOT NULL,
    reason        text NOT NULL DEFAULT '',
    change_id     integer,
    total_hours   numeric(12,2) NOT NULL DEFAULT 0,
    total_value   numeric(14,2) NOT NULL DEFAULT 0,
    finish_date   date,
    created_by    text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, number)
);

CREATE TABLE projects.baseline_item (
    baseline_id    integer NOT NULL REFERENCES projects.baseline(id) ON DELETE CASCADE,
    task_id        integer REFERENCES projects.task(id) ON DELETE SET NULL,
    code           text NOT NULL,
    name           text NOT NULL,
    kind           text NOT NULL,
    parent_code    text,
    planned_hours  numeric(10,2) NOT NULL DEFAULT 0,
    planned_start  date,
    planned_finish date,
    planned_value  numeric(14,2) NOT NULL DEFAULT 0,
    PRIMARY KEY (baseline_id, code)
);
CREATE INDEX baseline_item_task_idx ON projects.baseline_item (task_id);

-- Frozen: a baseline never changes (only its link to a deleted task is cleared).
CREATE FUNCTION projects.baseline_frozen() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND (to_jsonb(OLD) - 'task_id') = (to_jsonb(NEW) - 'task_id') THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'linha de base é imutável' USING ERRCODE = 'check_violation';
END $$;
CREATE TRIGGER baseline_item_frozen BEFORE UPDATE ON projects.baseline_item
    FOR EACH ROW EXECUTE FUNCTION projects.baseline_frozen();

-- ---------------------------------------------------------------- RF-021-07
CREATE TABLE projects.scope_change (
    id                   serial PRIMARY KEY,
    project_id           integer NOT NULL REFERENCES projects.project(id) ON DELETE CASCADE,
    number               integer NOT NULL,
    title                text NOT NULL CHECK (length(title) BETWEEN 3 AND 200),
    description          text NOT NULL DEFAULT '',
    requested_by         text NOT NULL,
    requested_at         timestamptz NOT NULL DEFAULT now(),
    est_hours            numeric(10,2) CHECK (est_hours >= 0),
    est_amount           numeric(14,2) CHECK (est_amount >= 0),
    est_days             integer CHECK (est_days >= 0),
    status               text NOT NULL DEFAULT 'requested'
                         CHECK (status IN ('requested', 'estimated', 'approved_internal', 'approved', 'rejected')),
    internal_approved_by text,
    internal_approved_at timestamptz,
    customer_approver    text,
    customer_approved_at timestamptz,
    rejection_reason     text,
    milestone_id         integer REFERENCES projects.milestone(id),
    baseline_id          integer REFERENCES projects.baseline(id),
    UNIQUE (project_id, number)
);
CREATE INDEX scope_change_milestone_idx ON projects.scope_change (milestone_id);
CREATE INDEX scope_change_baseline_idx ON projects.scope_change (baseline_id);
ALTER TABLE projects.baseline ADD CONSTRAINT baseline_change_fk
    FOREIGN KEY (change_id) REFERENCES projects.scope_change(id);
CREATE INDEX baseline_change_idx ON projects.baseline (change_id);

-- ---------------------------------------------------------------- RF-021-08
CREATE TABLE projects.risk (
    id             serial PRIMARY KEY,
    project_id     integer NOT NULL REFERENCES projects.project(id) ON DELETE CASCADE,
    kind           text NOT NULL DEFAULT 'risk' CHECK (kind IN ('risk', 'issue')),
    title          text NOT NULL CHECK (length(title) BETWEEN 3 AND 200),
    probability    smallint NOT NULL DEFAULT 3 CHECK (probability BETWEEN 1 AND 5),
    impact         smallint NOT NULL DEFAULT 3 CHECK (impact BETWEEN 1 AND 5),
    owner          text,
    action_plan    text NOT NULL DEFAULT '',
    due_date       date,
    status         text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'mitigating', 'closed')),
    client_visible boolean NOT NULL DEFAULT false,
    created_by     text NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX risk_project_idx ON projects.risk (project_id, status);

-- ---------------------------------------------------------------- RF-021-09
CREATE TABLE projects.status_report (
    id             serial PRIMARY KEY,
    project_id     integer NOT NULL REFERENCES projects.project(id) ON DELETE CASCADE,
    period_start   date NOT NULL,
    period_end     date NOT NULL,
    content        jsonb NOT NULL,
    client_visible boolean NOT NULL DEFAULT true,
    created_by     text NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX status_report_project_idx ON projects.status_report (project_id, period_end DESC);

-- ---------------------------------------------------------------- privileges
DO $$
BEGIN
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA projects TO ana_exec;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA projects TO ana_exec;
    GRANT SELECT ON projects.task_dependency, projects.template, projects.template_item, projects.absence,
                    projects.allocation, projects.baseline, projects.baseline_item, projects.scope_change,
                    projects.risk, projects.status_report TO ana_read;
    -- The SQL console keeps not seeing internal cost (RNF-008-02): weekly_hours is fine.
    GRANT SELECT (weekly_hours) ON projects.employee TO ana_read;
    GRANT USAGE ON SCHEMA scheduler TO ana_exec;
    GRANT SELECT ON scheduler.holiday TO ana_exec;     -- one holiday calendar in the ERP
    REVOKE EXECUTE ON FUNCTION projects.time_entry_activity_only(), projects.baseline_frozen() FROM PUBLIC;
END $$;
