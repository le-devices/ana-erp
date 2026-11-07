-- 061 — Events instead of polling (spec 062, D2): a committed write to the integration queues wakes the
-- workers of every node through NOTIFY (delivered only after COMMIT; once per statement, not per row).
CREATE FUNCTION integration.wake() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('ana_wake', 'integration');
    RETURN NULL;
END $$;
CREATE TRIGGER outbox_wake AFTER INSERT ON integration.outbox FOR EACH STATEMENT EXECUTE FUNCTION integration.wake();
CREATE TRIGGER inbox_wake AFTER INSERT ON integration.inbox FOR EACH STATEMENT EXECUTE FUNCTION integration.wake();
-- One worker per connector claims only its own messages (D4).
CREATE INDEX outbox_connector_due_idx ON integration.outbox (connector, next_at) WHERE status IN ('pending', 'processing');
CREATE INDEX inbox_connector_due_idx ON integration.inbox (connector, next_at) WHERE status IN ('pending', 'processing');

