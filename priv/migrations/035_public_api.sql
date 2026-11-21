-- 035 — Public API: clients, signed tokens, idempotency, limits and audit (spec 010)

-- RF-010-04: programs that a publishable key (anonymous browser) may call. Always exposed too.
ALTER TABLE ana_system.program ADD COLUMN public boolean NOT NULL DEFAULT false;
ALTER TABLE ana_system.program ADD CONSTRAINT program_public_exposed CHECK (NOT public OR exposed);

-- RF-010-01: API clients. Every call runs as the client's robot user (P14): the effective permission
-- is exposed ∩ scopes ∩ that user's role and groups.
CREATE TABLE ana_system.api_client (
    client_id        text PRIMARY KEY CHECK (client_id ~ '^ana_ci_[A-Za-z0-9]{16,48}$'),
    name             text NOT NULL CHECK (length(name) BETWEEN 2 AND 120),
    kind             text NOT NULL CHECK (kind IN ('confidential', 'browser', 'publishable')),
    run_as           text NOT NULL REFERENCES ana_system.app_user(username) ON UPDATE CASCADE,
    secret_hashes    text[] NOT NULL DEFAULT '{}' CHECK (cardinality(secret_hashes) <= 2),
    publishable_hash text UNIQUE,                         -- sha256 of the publishable key (kind publishable)
    signing_ct       bytea,                               -- HMAC key for signed requests (vault, spec 017)
    signing_nonce    bytea,
    signing_tag      bytea,
    origins          text[] NOT NULL DEFAULT '{}' CHECK (array_position(origins, NULL) IS NULL),
    redirect_uris    text[] NOT NULL DEFAULT '{}' CHECK (array_position(redirect_uris, NULL) IS NULL),
    scopes           text[] NOT NULL DEFAULT '{}' CHECK (array_position(scopes, NULL) IS NULL),
    ip_allow         cidr[] NOT NULL DEFAULT '{}',
    rate_per_minute  integer NOT NULL DEFAULT 600 CHECK (rate_per_minute BETWEEN 1 AND 1000000),
    daily_quota      integer CHECK (daily_quota > 0),
    require_signature boolean NOT NULL DEFAULT false,
    active           boolean NOT NULL DEFAULT true,
    expires_at       timestamptz,
    created_by       text NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

-- RNF-010-02: Ed25519 keys that sign access tokens (private part encrypted with the master key).
CREATE TABLE ana_system.signing_key (
    kid         text PRIMARY KEY CHECK (kid ~ '^[A-Za-z0-9_-]{8,40}$'),
    public_key  bytea NOT NULL CHECK (length(public_key) = 32),
    ciphertext  bytea NOT NULL,
    nonce       bytea NOT NULL,
    tag         bytea NOT NULL,
    active      boolean NOT NULL DEFAULT true,           -- signs new tokens (only one)
    created_at  timestamptz NOT NULL DEFAULT now(),
    retired_at  timestamptz                              -- still validates until its tokens expire
);
CREATE UNIQUE INDEX signing_key_one_active ON ana_system.signing_key (active) WHERE active;

-- RF-010-07: idempotent writes (kept 24 h; survives a node crash, so not UNLOGGED).
CREATE TABLE ana_system.api_idempotency (
    client_id   text NOT NULL,
    key         text NOT NULL CHECK (length(key) BETWEEN 8 AND 200),
    body_hash   text NOT NULL,
    status      text NOT NULL CHECK (status IN ('running', 'done')),
    http_status integer,
    response    jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL DEFAULT now() + interval '24 hours',
    PRIMARY KEY (client_id, key)
);
CREATE INDEX api_idempotency_expires_idx ON ana_system.api_idempotency (expires_at);

-- RF-010-06: nonces of signed requests inside the 5-minute window (shared by every node).
CREATE UNLOGGED TABLE ana_system.api_nonce (
    client_id  text NOT NULL,
    nonce      text NOT NULL,
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (client_id, nonce)
);
CREATE INDEX api_nonce_expires_idx ON ana_system.api_nonce (expires_at);

-- RNF-010-04: daily quota, consolidated from every node.
CREATE TABLE ana_system.api_usage (
    client_id text NOT NULL,
    day       date NOT NULL,
    calls     bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (client_id, day)
);

-- RF-010-11: every public call (written in batches).
CREATE TABLE ana_system.api_call_log (
    id              bigserial PRIMARY KEY,
    at              timestamptz NOT NULL DEFAULT now(),
    client_id       text,
    username        text,
    auth            text NOT NULL,
    ip              text,
    program         text,
    status          integer NOT NULL,
    duration_ms     integer,
    idempotency_key text
);
CREATE INDEX api_call_log_at_brin ON ana_system.api_call_log USING brin (at);
CREATE INDEX api_call_log_client_idx ON ana_system.api_call_log (client_id, at DESC);
