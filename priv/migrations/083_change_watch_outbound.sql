-- 083 — Change watch (spec 068), part 6: the way out through a connector, once and in order (T-068-08, D11).
--
-- A message of a rule carries an event id (rule + event): queued once per connector — a firing taken again after a
-- crash finds the message already queued — and sent in the connector's event id header, so the destination drops a
-- repeat even if the delivery itself is retried (at least once, spec 017). The ordering key (the record) keeps the
-- messages of one record in order.
ALTER TABLE integration.outbox ADD COLUMN event_id text CHECK (length(event_id) BETWEEN 1 AND 200);
CREATE UNIQUE INDEX outbox_event_once ON integration.outbox (connector, event_id) WHERE event_id IS NOT NULL;

CREATE FUNCTION integration.enqueue(p_connector text, p_kind text, p_payload jsonb, p_key text, p_event_id text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_id bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM integration.connector WHERE name = p_connector AND active
                   AND outbound_program IS NOT NULL) THEN
        RAISE EXCEPTION 'CONNECTOR_NOT_FOUND: conector % inexistente, inativo ou sem programa de entrega', p_connector
            USING ERRCODE = 'check_violation';
    END IF;
    INSERT INTO integration.outbox (connector, kind, payload, ordering_key, event_id, created_by)
    VALUES (p_connector, p_kind, p_payload, p_key, p_event_id,
            COALESCE(NULLIF(current_setting('ana.username', true), ''), '?'))
    ON CONFLICT (connector, event_id) WHERE event_id IS NOT NULL DO NOTHING
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        SELECT id INTO v_id FROM integration.outbox WHERE connector = p_connector AND event_id = p_event_id;
    END IF;
    RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION integration.enqueue(text, text, jsonb, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION integration.enqueue(text, text, jsonb, text, text) TO ana_exec;
