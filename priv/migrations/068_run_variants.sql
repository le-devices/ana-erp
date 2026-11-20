-- 068 — Execution variants (spec 045): named parameters of a routine, kept on the server — personal (only the owner)
-- or the company's (published by who may, read-only for the others) — with dynamic values from the closed list of
-- expressions and the company values (spec 065), locked and hidden fields, a default per user and per company.

CREATE TABLE ana_system.run_variant (
    id              serial PRIMARY KEY,
    program         text NOT NULL REFERENCES ana_system.program(name) ON UPDATE CASCADE ON DELETE CASCADE,
    name            text NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 80),
    owner           text REFERENCES ana_system.app_user(username) ON UPDATE CASCADE ON DELETE CASCADE,  -- NULL = the company's
    published       boolean NOT NULL DEFAULT false,                -- company variants: visible to everyone who runs it
    company_default boolean NOT NULL DEFAULT false,
    -- {"param": {"value": x} | {"expr": "last_month_start"} | {"company_value": "financeiro.periodo_aberto"}}
    entries         jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(entries) = 'object'),
    locked          text[] NOT NULL DEFAULT '{}',                  -- the user does not change them (screen, API, schedule)
    hidden          text[] NOT NULL DEFAULT '{}',                  -- not shown on screen (and locked as well)
    status          text NOT NULL DEFAULT 'valid' CHECK (status IN ('valid', 'invalid')),
    status_reason   text,
    version         integer NOT NULL DEFAULT 1,
    previous        jsonb,                                         -- the version before (company variants, RF-045-02)
    created_by      text NOT NULL,
    updated_by      text NOT NULL,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (owner IS NULL OR (NOT published AND NOT company_default)),
    CHECK (NOT company_default OR published)
);
CREATE UNIQUE INDEX run_variant_name_uk ON ana_system.run_variant (program, coalesce(owner, ''), lower(btrim(name)));
CREATE UNIQUE INDEX run_variant_company_default_uk ON ana_system.run_variant (program) WHERE company_default;
CREATE INDEX run_variant_owner_idx ON ana_system.run_variant (owner, program);
COMMENT ON TABLE ana_system.run_variant IS 'Variantes de execução: parâmetros com nome de uma rotina (spec 045)';

-- Each user's default variant of a routine (D4); without one, the company's default.
CREATE TABLE ana_system.run_variant_default (
    username   text NOT NULL REFERENCES ana_system.app_user(username) ON UPDATE CASCADE ON DELETE CASCADE,
    program    text NOT NULL REFERENCES ana_system.program(name) ON UPDATE CASCADE ON DELETE CASCADE,
    variant_id integer NOT NULL REFERENCES ana_system.run_variant(id) ON DELETE CASCADE,
    PRIMARY KEY (username, program)
);

-- Who may publish company variants (RF-045-02): programs or "prefix.*", besides administrators.
ALTER TABLE ana_system.access_group ADD COLUMN variant_patterns text[] NOT NULL DEFAULT '{}'
    CHECK (array_position(variant_patterns, NULL) IS NULL);

-- RF-045-06: the variant an execution used (with its version and the warnings), and a schedule that uses one.
ALTER TABLE ana_system.execution ADD COLUMN variant jsonb;
ALTER TABLE scheduler.job ADD COLUMN variant_id integer REFERENCES ana_system.run_variant(id) ON DELETE RESTRICT;
