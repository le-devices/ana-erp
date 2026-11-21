-- 058 — Outbound e-mail (spec 044): SMTP is a kind of connector; messages go through the outbox.

ALTER TABLE integration.connector DROP CONSTRAINT connector_kind_check;
ALTER TABLE integration.connector ADD CONSTRAINT connector_kind_check CHECK (kind IN ('http_api', 'webhook_in', 'smtp'));
ALTER TABLE integration.connector ADD COLUMN default_email boolean NOT NULL DEFAULT false;
ALTER TABLE integration.connector ADD CONSTRAINT connector_default_email_check CHECK (NOT default_email OR kind = 'smtp');
CREATE UNIQUE INDEX connector_default_email_idx ON integration.connector (default_email) WHERE default_email;
GRANT SELECT (default_email) ON integration.connector TO ana_exec;

-- D2: written in the business transaction (only leaves if it commits), owned by the execution's user.
CREATE FUNCTION integration.enqueue_email(p_connector text, p_message jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_name text;
    v_id bigint;
BEGIN
    SELECT name INTO v_name FROM integration.connector
     WHERE active AND kind = 'smtp' AND (name = p_connector OR (p_connector IS NULL AND default_email));
    IF v_name IS NULL THEN
        RAISE EXCEPTION 'EMAIL_CONNECTOR_NOT_FOUND: %', CASE WHEN p_connector IS NULL
            THEN 'nenhum conector de e-mail padrão ativo (Integrações → Conectores)'
            ELSE format('conector de e-mail %s inexistente, inativo ou não é SMTP', p_connector) END
            USING ERRCODE = 'check_violation';
    END IF;
    INSERT INTO integration.outbox (connector, kind, payload, created_by)
    VALUES (v_name, 'email', p_message, COALESCE(NULLIF(current_setting('ana.username', true), ''), '?'))
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION integration.enqueue_email(text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION integration.enqueue_email(text, jsonb) TO ana_exec;
