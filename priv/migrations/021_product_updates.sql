-- 021 — Product program updates offered to existing installations (spec 028)

ALTER TABLE ana_system.program ADD COLUMN seed_hash text;
COMMENT ON COLUMN ana_system.program.seed_hash IS 'SHA-256 da semente do produto em que o programa se baseia';

-- Existing installations: the version written by the seed is the base.
UPDATE ana_system.program p SET seed_hash = encode(sha256(convert_to(v.source, 'UTF8')), 'hex')
FROM ana_system.program_version v
WHERE v.name = p.name AND v.comment = 'seed' AND p.seed_hash IS NULL
  AND v.version = (SELECT min(version) FROM ana_system.program_version x WHERE x.name = p.name AND x.comment = 'seed');

CREATE TABLE ana_system.product_update (
    name             text PRIMARY KEY REFERENCES ana_system.program(name) ON DELETE CASCADE ON UPDATE CASCADE,
    seed_source      text NOT NULL,
    seed_hash        text NOT NULL CHECK (seed_hash ~ '^[0-9a-f]{64}$'),
    base_hash        text,
    locally_modified boolean NOT NULL,
    status           text NOT NULL DEFAULT 'available' CHECK (status IN ('available', 'accepted', 'dismissed')),
    detected_at      timestamptz NOT NULL DEFAULT now(),
    decided_at       timestamptz,
    decided_by       text,
    CHECK ((status = 'available') = (decided_at IS NULL))
);
CREATE INDEX product_update_available_idx ON ana_system.product_update (status) WHERE status = 'available';
