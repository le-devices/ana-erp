-- Spec 009 (phase 1): signed license of the instance and its state. Core data only (ana_system):
-- programs never read nor change it; the core caches the resulting state.

CREATE TABLE ana_system.license (
    id           bigserial PRIMARY KEY,
    text         text NOT NULL,                              -- the signed text, as delivered by the vendor
    payload      jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    kid          text NOT NULL,
    installed_by text NOT NULL,
    installed_at timestamptz NOT NULL DEFAULT now(),
    source       text NOT NULL CHECK (source IN ('screen', 'file')),
    active       boolean NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX license_one_active ON ana_system.license (active) WHERE active;
COMMENT ON TABLE ana_system.license IS 'Licenças instaladas (a ativa vale; as outras são histórico)';

-- One row: when the evaluation started (first start with licensing) and the latest date ever seen
-- (a server clock set back cannot extend a license).
CREATE TABLE ana_system.license_state (
    id         integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    first_boot date NOT NULL DEFAULT current_date,
    last_seen  date NOT NULL DEFAULT current_date
);
INSERT INTO ana_system.license_state DEFAULT VALUES;

-- Every node of the cluster recomputes its cached state when the license changes.
CREATE FUNCTION ana_system.license_changed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('ana_license', '');
    RETURN NULL;
END $$;
CREATE TRIGGER license_changed AFTER INSERT OR UPDATE ON ana_system.license
    FOR EACH STATEMENT EXECUTE FUNCTION ana_system.license_changed();

-- The BPM warns, when publishing, about steps whose program belongs to a module outside the license
-- (spec 009, RF-009-03). Only the module list leaves ana_system; no license means every module (evaluation).
CREATE FUNCTION bpm.licensed_modules() RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT COALESCE((SELECT array_agg(m) FROM ana_system.license l, jsonb_array_elements_text(l.payload->'modules') m
                      WHERE l.active),
                    ARRAY['sales', 'supply', 'production', 'logistics_field', 'projects', 'bpm', 'analytics', 'public_api', 'portal'])
$$;
REVOKE ALL ON FUNCTION bpm.licensed_modules() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bpm.licensed_modules() TO ana_exec;
