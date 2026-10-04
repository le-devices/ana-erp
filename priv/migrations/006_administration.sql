-- 006 — Day-to-day administration (spec 011)

ALTER TABLE ana_system.app_user
    ADD COLUMN must_change_password boolean NOT NULL DEFAULT false,
    ADD COLUMN last_login_at timestamptz;

-- RF-011-04: business access groups
CREATE TABLE ana_system.access_group (
    name             text PRIMARY KEY CHECK (name ~ '^[a-z][a-z0-9_-]{1,62}$'),
    description      text NOT NULL DEFAULT '',
    program_patterns text[] NOT NULL DEFAULT '{}'
        CHECK (array_position(program_patterns, NULL) IS NULL)
);

CREATE TABLE ana_system.user_group (
    username   text NOT NULL REFERENCES ana_system.app_user(username) ON DELETE CASCADE ON UPDATE CASCADE,
    group_name text NOT NULL REFERENCES ana_system.access_group(name) ON DELETE CASCADE ON UPDATE CASCADE,
    PRIMARY KEY (username, group_name)
);
CREATE INDEX user_group_group_idx ON ana_system.user_group (group_name);

ALTER TABLE ana_system.program ADD COLUMN restricted boolean NOT NULL DEFAULT false;

-- RF-011-05: settings (validated by the core; see ana_settings)
CREATE TABLE ana_system.setting (
    key        text PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]*$'),
    value      jsonb NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by text NOT NULL
);

-- RF-011-09: audit
CREATE TABLE ana_system.login_event (
    id        bigserial PRIMARY KEY,
    username  text NOT NULL,
    ip        text NOT NULL,
    success   boolean NOT NULL,
    reason    text,
    at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX login_event_at_brin ON ana_system.login_event USING brin (at);
CREATE INDEX login_event_username_idx ON ana_system.login_event (username, at DESC);

CREATE TABLE ana_system.admin_log (
    id        bigserial PRIMARY KEY,
    username  text NOT NULL,
    action    text NOT NULL,
    target    text NOT NULL,
    before    jsonb,
    after     jsonb,
    at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX admin_log_at_brin ON ana_system.admin_log USING brin (at);
