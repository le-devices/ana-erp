-- 014 — Project financials: profit from allocation, viability projection, scenarios, margin policy
-- (spec 021, RF-021-12..15)

ALTER TABLE projects.rate_profile
    ADD COLUMN standard_cost numeric(12,2) CHECK (standard_cost >= 0);
COMMENT ON COLUMN projects.rate_profile.standard_cost IS 'Custo-hora padrão do perfil (projeções sem pessoa definida; confidencial)';

CREATE TABLE projects.planned_expense (
    id            serial PRIMARY KEY,
    project_id    integer NOT NULL REFERENCES projects.project(id) ON DELETE CASCADE,
    description   text NOT NULL CHECK (length(description) BETWEEN 2 AND 200),
    kind          text NOT NULL DEFAULT 'other'
                  CHECK (kind IN ('component', 'pcb', 'supplies', 'subcontract', 'travel', 'software', 'other')),
    amount        numeric(14,2) NOT NULL CHECK (amount >= 0),
    monthly       boolean NOT NULL DEFAULT false,
    expected_date date,
    rebillable    boolean NOT NULL DEFAULT false,
    markup_pct    numeric(6,2) NOT NULL DEFAULT 0 CHECK (markup_pct BETWEEN 0 AND 1000),
    created_by    text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX planned_expense_project_idx ON projects.planned_expense (project_id);

CREATE TABLE projects.policy (
    id                integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    target_margin_pct numeric(5,2) NOT NULL DEFAULT 30 CHECK (target_margin_pct BETWEEN -100 AND 100),
    min_margin_pct    numeric(5,2) NOT NULL DEFAULT 15 CHECK (min_margin_pct BETWEEN -100 AND 100),
    overhead_pct      numeric(6,2) NOT NULL DEFAULT 0 CHECK (overhead_pct BETWEEN 0 AND 500),
    -- RF-021-14a: variations of the optimistic and pessimistic scenarios (company defaults).
    optimistic_hours_pct   numeric(6,2) NOT NULL DEFAULT -10 CHECK (optimistic_hours_pct BETWEEN -90 AND 500),
    optimistic_cost_pct    numeric(6,2) NOT NULL DEFAULT 0 CHECK (optimistic_cost_pct BETWEEN -90 AND 500),
    optimistic_rate_pct    numeric(6,2) NOT NULL DEFAULT 0 CHECK (optimistic_rate_pct BETWEEN -90 AND 500),
    optimistic_delay_weeks integer NOT NULL DEFAULT 0 CHECK (optimistic_delay_weeks BETWEEN 0 AND 260),
    pessimistic_hours_pct   numeric(6,2) NOT NULL DEFAULT 20 CHECK (pessimistic_hours_pct BETWEEN -90 AND 500),
    pessimistic_cost_pct    numeric(6,2) NOT NULL DEFAULT 10 CHECK (pessimistic_cost_pct BETWEEN -90 AND 500),
    pessimistic_rate_pct    numeric(6,2) NOT NULL DEFAULT 0 CHECK (pessimistic_rate_pct BETWEEN -90 AND 500),
    pessimistic_delay_weeks integer NOT NULL DEFAULT 4 CHECK (pessimistic_delay_weeks BETWEEN 0 AND 260),
    updated_by        text,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CHECK (min_margin_pct <= target_margin_pct)
);
INSERT INTO projects.policy (id) VALUES (1) ON CONFLICT DO NOTHING;

CREATE TABLE projects.scenario (
    id          serial PRIMARY KEY,
    project_id  integer NOT NULL REFERENCES projects.project(id) ON DELETE CASCADE,
    name        text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
    -- optimistic/pessimistic override the company defaults for this project (RF-021-14a)
    kind        text NOT NULL DEFAULT 'custom' CHECK (kind IN ('optimistic', 'pessimistic', 'custom')),
    rate_pct    numeric(6,2) NOT NULL DEFAULT 0 CHECK (rate_pct BETWEEN -90 AND 500),
    hours_pct   numeric(6,2) NOT NULL DEFAULT 0 CHECK (hours_pct BETWEEN -90 AND 500),
    cost_pct    numeric(6,2) NOT NULL DEFAULT 0 CHECK (cost_pct BETWEEN -90 AND 500),
    delay_weeks integer NOT NULL DEFAULT 0 CHECK (delay_weeks BETWEEN 0 AND 260),
    notes       text NOT NULL DEFAULT '',
    created_by  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, name)
);
CREATE UNIQUE INDEX scenario_kind_uk ON projects.scenario (project_id, kind) WHERE kind <> 'custom';

ALTER TABLE projects.baseline
    ADD COLUMN projected_revenue        numeric(14,2),
    ADD COLUMN projected_cost           numeric(14,2),
    ADD COLUMN projected_profit         numeric(14,2),
    ADD COLUMN low_margin_justification text;

DO $$
BEGIN
    GRANT SELECT, INSERT, UPDATE, DELETE ON projects.planned_expense, projects.policy, projects.scenario TO ana_exec;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA projects TO ana_exec;
    -- Costs and margins are confidential: the SQL console sees neither (RNF-008-02 / RNF-021-02).
    GRANT SELECT (id, project_id, description, kind, monthly, expected_date, rebillable, created_by, created_at)
        ON projects.planned_expense TO ana_read;
    GRANT SELECT (id, project_id, name, kind, rate_pct, hours_pct, delay_weeks, notes, created_by, created_at)
        ON projects.scenario TO ana_read;
    REVOKE SELECT ON projects.rate_profile FROM ana_read;
    GRANT SELECT (code, description, hourly_rate, active) ON projects.rate_profile TO ana_read;
    REVOKE SELECT ON projects.baseline FROM ana_read;
    GRANT SELECT (id, project_id, number, reason, change_id, total_hours, finish_date, created_by, created_at)
        ON projects.baseline TO ana_read;
END $$;
