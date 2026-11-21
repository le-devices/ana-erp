-- 074 — Continuous usage simulation (spec 067, phase 1): personas, runs and findings.

-- D1: personas — each runs as a robot user ("sim_<name>") with a real role and groups, a working day (how often each
-- scenario) and a rate of human mistakes.
CREATE TABLE ana_system.sim_persona (
    name        text PRIMARY KEY CHECK (name ~ '^[a-z][a-z0-9_]{1,30}$'),
    label       text NOT NULL,
    role        text NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'developer')),
    groups      text[] NOT NULL DEFAULT '{}' CHECK (array_position(groups, NULL) IS NULL),
    error_rate  numeric(4,3) NOT NULL DEFAULT 0.05 CHECK (error_rate BETWEEN 0 AND 0.5),
    active      boolean NOT NULL DEFAULT true
);
INSERT INTO ana_system.sim_persona (name, label, error_rate) VALUES
    ('vendedor', 'Vendedor', 0.08), ('comprador', 'Comprador', 0.05), ('almoxarife', 'Almoxarife', 0.05),
    ('financeiro', 'Financeiro', 0.03), ('tecnico', 'Técnico de campo', 0.08), ('gestor', 'Gestor de projetos', 0.05),
    ('aprovador', 'Aprovador de compras', 0.02), ('producao', 'Planejador da produção', 0.05);

-- D6: each run — seed, days, scenarios per day; the steps ran; the findings, compared with the previous run.
CREATE TABLE ana_system.sim_run (
    id            bigserial PRIMARY KEY,
    seed          bigint NOT NULL,
    days          integer NOT NULL CHECK (days BETWEEN 1 AND 60),
    per_day       integer NOT NULL CHECK (per_day BETWEEN 1 AND 200),
    options       jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(options) = 'object'),
    status        text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'done', 'failed', 'stopped')),
    started_by    text NOT NULL,
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    stats         jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(stats) = 'object'),
    steps         jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(steps) = 'array'),
    reason        text
);
CREATE UNIQUE INDEX sim_run_one_at_a_time ON ana_system.sim_run ((true)) WHERE status = 'running';

-- D4: what was found, with what reproduces it (seed, scenario, persona, steps) and the executions involved.
CREATE TABLE ana_system.sim_finding (
    id            bigserial PRIMARY KEY,
    run_id        bigint NOT NULL REFERENCES ana_system.sim_run(id) ON DELETE CASCADE,
    fingerprint   text NOT NULL CHECK (fingerprint ~ '^[0-9a-f]{16}$'),
    category      text NOT NULL CHECK (category IN ('automation', 'accounts', 'usability', 'robustness', 'performance', 'access')),
    severity      text NOT NULL CHECK (severity IN ('info', 'warning', 'serious', 'critical')),
    title         text NOT NULL CHECK (length(title) BETWEEN 3 AND 300),
    detail        jsonb NOT NULL DEFAULT '{}',
    scenario      text,
    persona       text,
    seed          bigint,
    steps         jsonb NOT NULL DEFAULT '[]',
    trend         text NOT NULL DEFAULT 'new' CHECK (trend IN ('new', 'persistent')),
    UNIQUE (run_id, fingerprint)
);
CREATE INDEX sim_finding_fp_idx ON ana_system.sim_finding (fingerprint);
COMMENT ON TABLE ana_system.sim_finding IS 'Achados do uso simulado contínuo (spec 067)';
