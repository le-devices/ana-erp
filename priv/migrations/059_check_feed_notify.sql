-- 059 — Periodic checks (spec 033, T-033-09b): the vulnerability base updated by a hub connector,
-- and new findings sent through a connector (e-mail or chat). One row of configuration and state.
CREATE TABLE ana_system.check_config (
    id                  boolean PRIMARY KEY DEFAULT true CHECK (id),
    notify_connector    text REFERENCES integration.connector(name) ON UPDATE CASCADE ON DELETE SET NULL,
    notify_recipients   text[] NOT NULL DEFAULT '{}'
                        CHECK (cardinality(notify_recipients) <= 50 AND array_position(notify_recipients, NULL) IS NULL),
    notify_min_severity text NOT NULL DEFAULT 'critical' CHECK (notify_min_severity IN ('warning', 'serious', 'critical')),
    feed_connector      text,
    feed_at             timestamptz,
    feed_ok             boolean,
    feed_message        text,
    feed_advisories     integer,
    updated_by          text,
    updated_at          timestamptz
);
INSERT INTO ana_system.check_config DEFAULT VALUES;
