-- 030 — Development/test instance: transport packages and masked data copies (spec 034)

-- RF-034-02: Ed25519 key of this instance (private part encrypted with the master key, spec 017).
CREATE TABLE ana_system.instance_key (
    id          integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    public_key  bytea NOT NULL CHECK (length(public_key) = 32),
    ciphertext  bytea NOT NULL,
    nonce       bytea NOT NULL,
    tag         bytea NOT NULL,
    created_by  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Origins whose packages this instance accepts.
CREATE TABLE ana_system.transport_origin (
    name        text PRIMARY KEY CHECK (name ~ '^[a-z][a-z0-9_-]{1,62}$'),
    public_key  bytea NOT NULL CHECK (length(public_key) = 32),
    active      boolean NOT NULL DEFAULT true,
    created_by  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- RF-034-05: packages sent (out) and received (in), with their whole history.
CREATE TABLE ana_system.transport (
    id              bigserial PRIMARY KEY,
    direction       text NOT NULL CHECK (direction IN ('out', 'in')),
    title           text NOT NULL CHECK (length(title) BETWEEN 3 AND 200),
    description     text NOT NULL DEFAULT '',
    author          text NOT NULL,
    origin          text NOT NULL,
    status          text NOT NULL CHECK (status IN ('exported', 'received', 'imported', 'refused', 'reverted')),
    manifest        jsonb NOT NULL,
    manifest_sha256 text NOT NULL CHECK (manifest_sha256 ~ '^[0-9a-f]{64}$'),
    preflight       jsonb,
    received_by     text,
    received_at     timestamptz,
    imported_by     text,
    imported_at     timestamptz,
    reverted_by     text,
    reverted_at     timestamptz,
    refused_by      text,
    refused_reason  text,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX transport_created_idx ON ana_system.transport (created_at DESC);
-- The same package is not received twice (unless refused).
CREATE UNIQUE INDEX transport_in_once_idx ON ana_system.transport (manifest_sha256)
    WHERE direction = 'in' AND status <> 'refused';

CREATE TABLE ana_system.transport_item (
    transport_id    bigint NOT NULL REFERENCES ana_system.transport(id) ON DELETE CASCADE,
    seq             integer NOT NULL,
    kind            text NOT NULL CHECK (kind IN ('program', 'command', 'setting')),
    name            text NOT NULL,
    new_sha256      text NOT NULL,
    base_sha256     text,
    previous        jsonb,          -- state on this instance before the import (for undo)
    created_version integer,
    PRIMARY KEY (transport_id, seq)
);

-- RF-034-06: masked data copies (export on production, import on test/development).
CREATE TABLE ana_system.datacopy (
    id          bigserial PRIMARY KEY,
    direction   text NOT NULL CHECK (direction IN ('out', 'in')),
    status      text NOT NULL CHECK (status IN ('running', 'ready', 'uploaded', 'imported', 'checked', 'failed', 'expired')),
    file_path   text,
    size_bytes  bigint,
    manifest    jsonb,
    result      jsonb,
    error       text,
    created_by  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz
);
CREATE INDEX datacopy_created_idx ON ana_system.datacopy (created_at DESC);

-- Masking rules per column (installation adjustments over the product catalog).
CREATE TABLE ana_system.mask_rule (
    schema_name text NOT NULL,
    table_name  text NOT NULL,
    column_name text NOT NULL,
    kind        text NOT NULL CHECK (kind IN ('keep', 'person', 'company', 'email', 'phone', 'document', 'address', 'geo', 'text', 'null')),
    updated_by  text NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (schema_name, table_name, column_name)
);
