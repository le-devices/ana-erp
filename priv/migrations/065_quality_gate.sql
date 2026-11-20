-- 065 — Quality gate of programs (spec 064, phase 1): baseline and exemptions.
-- Findings are identified by their fingerprint (rule + the text of their line), so they survive lines moving.

-- Baseline (D3): findings that already existed when the gate was adopted do not block an old program;
-- only new ones do.
CREATE TABLE ana_system.quality_baseline (
    program     text NOT NULL REFERENCES ana_system.program(name) ON DELETE CASCADE ON UPDATE CASCADE,
    fingerprint text NOT NULL CHECK (fingerprint ~ '^[0-9a-f]{16}$'),
    rule        text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text NOT NULL,
    PRIMARY KEY (program, fingerprint)
);
COMMENT ON TABLE ana_system.quality_baseline IS 'Portão de qualidade: achados antigos que não bloqueiam (só os novos bloqueiam)';

-- Exemptions (D3, CA-064-02): justified, with a deadline, approved by someone else — never by who asked.
CREATE TABLE ana_system.quality_exemption (
    id           bigserial PRIMARY KEY,
    program      text NOT NULL REFERENCES ana_system.program(name) ON DELETE CASCADE ON UPDATE CASCADE,
    fingerprint  text NOT NULL CHECK (fingerprint ~ '^[0-9a-f]{16}$'),
    rule         text NOT NULL,
    reason       text NOT NULL CHECK (length(btrim(reason)) BETWEEN 10 AND 2000),
    valid_until  date NOT NULL,
    status       text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested', 'approved', 'refused')),
    requested_by text NOT NULL,
    requested_at timestamptz NOT NULL DEFAULT now(),
    decided_by   text,
    decided_at   timestamptz,
    decision     text,
    CHECK ((status = 'requested') = (decided_by IS NULL)),
    CHECK (decided_by IS NULL OR decided_by <> requested_by)          -- four eyes, enforced by the database
);
CREATE INDEX quality_exemption_program_idx ON ana_system.quality_exemption (program, fingerprint);
CREATE UNIQUE INDEX quality_exemption_open_uk ON ana_system.quality_exemption (program, fingerprint) WHERE status = 'requested';
COMMENT ON TABLE ana_system.quality_exemption IS 'Portão de qualidade: isenções por achado, com motivo, prazo e aprovação de outra pessoa';
