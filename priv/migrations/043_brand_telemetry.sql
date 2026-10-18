-- Spec 009 phase 3: the customer's brand beside ANA's (D11) and optional, consented telemetry (D13).

-- Display name and logo (JPEG, base64; the browser converts and shrinks any image before sending).
ALTER TABLE base.company
    ADD COLUMN display_name text CHECK (display_name IS NULL OR length(btrim(display_name)) BETWEEN 2 AND 60),
    ADD COLUMN logo text CHECK (logo IS NULL OR (length(logo) <= 400000 AND logo ~ '^/9j/'));   -- JPEG magic in base64

-- One row: off by default. An anonymous instance id (not the customer's identity) correlates the reports.
CREATE TABLE ana_system.telemetry (
    id           integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    enabled      boolean NOT NULL DEFAULT false,
    instance_id  uuid NOT NULL DEFAULT gen_random_uuid(),
    changed_by   text,
    changed_at   timestamptz,
    last_sent_at timestamptz,
    last_status  text,
    last_payload jsonb
);
INSERT INTO ana_system.telemetry DEFAULT VALUES;
COMMENT ON TABLE ana_system.telemetry IS 'Telemetria opcional para o suporte do fornecedor: só versão, saúde e contagens';
