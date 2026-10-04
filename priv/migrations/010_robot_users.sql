-- 010 — Robot users and API keys (spec 011, RF-011-12..15)

ALTER TABLE ana_system.app_user
    ADD COLUMN kind text NOT NULL DEFAULT 'human' CHECK (kind IN ('human', 'robot')),
    ADD CONSTRAINT robot_not_admin CHECK (kind <> 'robot' OR role <> 'admin');

CREATE TABLE ana_system.api_key (
    id           serial PRIMARY KEY,
    username     text NOT NULL REFERENCES ana_system.app_user(username) ON DELETE CASCADE ON UPDATE CASCADE,
    name         text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
    prefix       text NOT NULL,
    key_hash     bytea NOT NULL UNIQUE,
    ip_allow     cidr[] NOT NULL DEFAULT '{}',
    expires_at   timestamptz,
    last_used_at timestamptz,
    revoked_at   timestamptz,
    created_by   text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX api_key_username_idx ON ana_system.api_key (username);

-- Every execution has an owner (constitution P14, RF-011-16): a real, active
-- user — person or robot. Internal tasks belong to the built-in robot "system".
ALTER TABLE ana_system.app_user
    ADD COLUMN builtin boolean NOT NULL DEFAULT false,
    ADD CONSTRAINT builtin_is_robot CHECK (NOT builtin OR kind = 'robot');

INSERT INTO ana_system.app_user (username, name, password_hash, role, active, must_change_password, kind, builtin)
VALUES ('system', 'Tarefas internas do ERP', 'robot$builtin', 'developer', true, false, 'robot', true)
ON CONFLICT (username) DO UPDATE SET kind = 'robot', builtin = true, role = 'developer', active = true,
                                     password_hash = 'robot$builtin', must_change_password = false;

ALTER TABLE ana_system.execution
    ADD CONSTRAINT execution_owner_fk FOREIGN KEY (username)
        REFERENCES ana_system.app_user(username) ON UPDATE CASCADE NOT VALID;
ALTER TABLE ana_system.execution VALIDATE CONSTRAINT execution_owner_fk;

ALTER TABLE scheduler.job
    ADD CONSTRAINT job_owner_fk FOREIGN KEY (owner)
        REFERENCES ana_system.app_user(username) ON UPDATE CASCADE;

-- Internal tasks that are not programs (seeding, analytics refresh…), with owner.
CREATE TABLE ana_system.task_run (
    id          bigserial PRIMARY KEY,
    task        text NOT NULL,
    username    text NOT NULL REFERENCES ana_system.app_user(username) ON UPDATE CASCADE,
    origin      text NOT NULL CHECK (origin IN ('internal', 'studio', 'api')),
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    status      text NOT NULL CHECK (status IN ('running', 'success', 'error')),
    detail      text
);
CREATE INDEX task_run_started_brin ON ana_system.task_run USING brin (started_at);
CREATE INDEX task_run_task_idx ON ana_system.task_run (task, started_at DESC);
