-- 073 — Tests of programs, coverage and performance against the previous version (spec 064, phase 2).

-- D4/D5: each run of a program's tests — run in rehearsals (everything undone, external effects held), with the lines
-- that ran, and the same tests on the previous version for comparison. The latest run of the current version feeds
-- the quality gate.
CREATE TABLE ana_system.program_test_run (
    id                bigserial PRIMARY KEY,
    program           text NOT NULL REFERENCES ana_system.program(name) ON UPDATE CASCADE ON DELETE CASCADE,
    version           integer NOT NULL,
    sha256            text NOT NULL,
    run_at            timestamptz NOT NULL DEFAULT now(),
    run_by            text NOT NULL,
    passed            integer NOT NULL DEFAULT 0,
    failed            integer NOT NULL DEFAULT 0,
    executed_lines    integer NOT NULL DEFAULT 0,
    executable_lines  integer NOT NULL DEFAULT 0,
    coverage          numeric(5,1),
    results           jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(results) = 'array'),
    previous_version  integer,
    regressions       jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(regressions) = 'array')
);
CREATE INDEX program_test_run_program_idx ON ana_system.program_test_run (program, run_at DESC);
COMMENT ON TABLE ana_system.program_test_run IS 'Testes dos programas, cobertura e desempenho comparado (spec 064)';
