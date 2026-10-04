-- 001 — ANA internal schema (specs 001, 002, 003, 005)
-- Runs as the database owner. The ana_system schema is NEVER reachable by the
-- ana_exec role (P10).

CREATE SCHEMA IF NOT EXISTS ana_system;
REVOKE ALL ON SCHEMA ana_system FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- Restricted roles (P10, spec 001 plan "Segurança")
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ana_exec') THEN
        CREATE ROLE ana_exec NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ana_read') THEN
        CREATE ROLE ana_read NOLOGIN;
    END IF;
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO ana_exec, ana_read', current_database());
END $$;
-- Roles get LOGIN and a password at core startup (ana_app:configure_roles/0):
-- programs and the SQL console use connections authenticated as these roles,
-- so SQL cannot "go back" to the owner with RESET ROLE.

-- Users (RF-001-03)
CREATE TABLE ana_system.app_user (
    username      text PRIMARY KEY CHECK (username ~ '^[a-z][a-z0-9_.-]{1,62}$'),
    name          text NOT NULL DEFAULT '',
    password_hash text NOT NULL,                -- pbkdf2_sha256$iter$salt$hash
    role          text NOT NULL CHECK (role IN ('admin', 'developer', 'user')),
    active        boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- Sessions: UNLOGGED — ephemeral, no WAL (spec 001 plan "Sessões")
CREATE UNLOGGED TABLE ana_system.session (
    token_hash  bytea PRIMARY KEY,
    username    text NOT NULL REFERENCES ana_system.app_user(username) ON DELETE CASCADE ON UPDATE CASCADE,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL
);
CREATE INDEX session_expires_idx ON ana_system.session (expires_at);
CREATE INDEX session_username_idx ON ana_system.session (username);

-- Programs (RF-002-01, RF-002-02)
CREATE TABLE ana_system.program (
    name        text PRIMARY KEY
                CHECK (name ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$' AND length(name) <= 128),
    description text NOT NULL DEFAULT '',
    kind        text NOT NULL DEFAULT 'program' CHECK (kind IN ('program', 'library')),
    exposed     boolean NOT NULL DEFAULT false,
    min_role    text NOT NULL DEFAULT 'user' CHECK (min_role IN ('admin', 'developer', 'user')),
    active      boolean NOT NULL DEFAULT true,
    version     integer NOT NULL DEFAULT 1,
    source      text NOT NULL,
    params      jsonb,
    docs        text,
    warning     text,                         -- syntax problem found on last save
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  text NOT NULL
);

CREATE TABLE ana_system.program_version (
    name        text NOT NULL REFERENCES ana_system.program(name) ON DELETE CASCADE,
    version     integer NOT NULL,
    source      text NOT NULL,
    comment     text NOT NULL DEFAULT '',
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text NOT NULL,
    PRIMARY KEY (name, version)
);

-- Executions (RF-002-09) — written outside the execution transaction (P11)
CREATE TABLE ana_system.execution (
    id           uuid PRIMARY KEY,
    program      text NOT NULL,
    version      integer,
    username     text NOT NULL,
    origin       text NOT NULL CHECK (origin IN ('studio', 'remote', 'internal', 'api')),
    debug        boolean NOT NULL DEFAULT false,
    started_at   timestamptz NOT NULL DEFAULT now(),
    finished_at  timestamptz,
    duration_ms  integer,
    status       text NOT NULL CHECK (status IN ('running', 'success', 'error', 'aborted', 'timeout')),
    params       jsonb,
    result       jsonb,
    error        jsonb,
    output       text
);
CREATE INDEX execution_started_brin ON ana_system.execution USING brin (started_at);
CREATE INDEX execution_program_idx ON ana_system.execution (program, started_at DESC);
CREATE INDEX execution_username_idx ON ana_system.execution (username, started_at DESC);

-- Remote systems for outbound calls (RF-003-08)
CREATE TABLE ana_system.remote_system (
    name        text PRIMARY KEY CHECK (name ~ '^[a-z][a-z0-9_]{0,62}$'),
    url         text NOT NULL CHECK (url ~ '^https?://'),
    username    text,
    password    text,
    timeout_ms  integer NOT NULL DEFAULT 15000 CHECK (timeout_ms BETWEEN 100 AND 120000),
    active      boolean NOT NULL DEFAULT true
);

-- Studio commands (RF-005-06)
CREATE TABLE ana_system.command (
    code        text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{0,31}$'),
    program     text NOT NULL REFERENCES ana_system.program(name) ON DELETE CASCADE,
    description text NOT NULL DEFAULT ''
);
CREATE INDEX command_program_idx ON ana_system.command (program);
