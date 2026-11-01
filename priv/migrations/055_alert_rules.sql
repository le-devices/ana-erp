-- Spec 019 (RF-019-08, T-019-08b): configurable alert rules and silences.
-- A rule watches a component's health or a node metric; the condition must hold
-- for the whole window before an incident opens. Silences keep incidents
-- recorded but quiet; they are ended, never deleted (history).

CREATE TABLE ana_system.alert_rule (
    id          bigserial PRIMARY KEY,
    name        text NOT NULL UNIQUE CHECK (length(name) BETWEEN 3 AND 120),
    source      text NOT NULL CHECK (source IN ('health', 'metric')),
    target      text NOT NULL CHECK (target ~ '^(\*|[a-z][a-z0-9_]{1,62})$'),
    level       text CHECK (level IN ('yellow', 'red')),
    op          text CHECK (op IN ('>', '>=', '<', '<=')),
    threshold   numeric,
    window_s    integer NOT NULL DEFAULT 0 CHECK (window_s BETWEEN 0 AND 86400),
    severity    text NOT NULL DEFAULT 'warning' CHECK (severity IN ('info', 'warning', 'serious', 'critical')),
    notify_studio boolean NOT NULL DEFAULT true,
    connector   text REFERENCES integration.connector(name) ON UPDATE CASCADE ON DELETE SET NULL,
    recipients  text[] NOT NULL DEFAULT '{}'
                CHECK (cardinality(recipients) <= 50 AND array_position(recipients, NULL) IS NULL),
    active      boolean NOT NULL DEFAULT true,
    updated_by  text NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (CASE source WHEN 'health' THEN level IS NOT NULL AND op IS NULL
                       ELSE level IS NULL AND op IS NOT NULL AND threshold IS NOT NULL AND target <> '*' END)
);

CREATE TABLE ana_system.alert_silence (
    id          bigserial PRIMARY KEY,
    rule_id     bigint REFERENCES ana_system.alert_rule(id) ON DELETE CASCADE,
    target      text CHECK (target ~ '^[a-z][a-z0-9_]{1,62}$'),
    node        text,
    starts_at   timestamptz NOT NULL DEFAULT now(),
    ends_at     timestamptz NOT NULL,
    reason      text NOT NULL CHECK (length(reason) BETWEEN 3 AND 500),
    created_by  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (ends_at > starts_at AND ends_at <= starts_at + interval '30 days')
);
CREATE INDEX alert_silence_ends_idx ON ana_system.alert_silence (ends_at);

-- The built-in behaviour (a red component opens a critical incident) becomes the first rule.
INSERT INTO ana_system.alert_rule (name, source, target, level, severity, updated_by)
VALUES ('Componente em falha', 'health', '*', 'red', 'critical', 'system');

ALTER TABLE ana_system.incident
    ADD COLUMN rule_id     bigint REFERENCES ana_system.alert_rule(id) ON DELETE SET NULL,
    ADD COLUMN severity    text NOT NULL DEFAULT 'critical' CHECK (severity IN ('info', 'warning', 'serious', 'critical')),
    ADD COLUMN notified_at timestamptz,
    ADD COLUMN silenced    boolean NOT NULL DEFAULT false;
UPDATE ana_system.incident SET rule_id = (SELECT id FROM ana_system.alert_rule WHERE name = 'Componente em falha'),
                               notified_at = opened_at;

DROP INDEX ana_system.incident_open_idx;
CREATE UNIQUE INDEX incident_open_idx ON ana_system.incident (COALESCE(rule_id, 0), component, node) WHERE closed_at IS NULL;
