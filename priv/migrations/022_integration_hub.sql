-- 022 — Integration hub: connectors, vault, reliable messaging, bank statements,
-- reconciliation and gateway charges (spec 017)

CREATE SCHEMA IF NOT EXISTS integration;
REVOKE ALL ON SCHEMA integration FROM PUBLIC;

-- RF-017-01
CREATE TABLE integration.connector (
    name             text PRIMARY KEY CHECK (name ~ '^[a-z][a-z0-9_]{1,62}$'),
    description      text NOT NULL DEFAULT '',
    kind             text NOT NULL CHECK (kind IN ('http_api', 'webhook_in')),
    base_url         text CHECK (base_url ~ '^https?://[^/?#@]+(/[^?#]*)?$'),
    auth             text NOT NULL DEFAULT 'none'
                     CHECK (auth IN ('none', 'basic', 'bearer', 'api_key', 'oauth2_client')),
    api_key_header   text NOT NULL DEFAULT 'X-API-Key' CHECK (api_key_header ~ '^[A-Za-z0-9-]{1,64}$'),
    token_url        text CHECK (token_url ~ '^https://'),
    allowed_hosts    text[] NOT NULL DEFAULT '{}' CHECK (array_position(allowed_hosts, NULL) IS NULL),
    timeout_ms       integer NOT NULL DEFAULT 15000 CHECK (timeout_ms BETWEEN 100 AND 120000),
    rate_per_min     integer NOT NULL DEFAULT 600 CHECK (rate_per_min BETWEEN 1 AND 100000),
    outbound_program text REFERENCES ana_system.program(name) ON UPDATE CASCADE,
    inbound_program  text REFERENCES ana_system.program(name) ON UPDATE CASCADE,
    signature_header text NOT NULL DEFAULT 'X-Signature' CHECK (signature_header ~ '^[A-Za-z0-9-]{1,64}$'),
    timestamp_header text NOT NULL DEFAULT 'X-Timestamp' CHECK (timestamp_header ~ '^[A-Za-z0-9-]{1,64}$'),
    event_id_header  text NOT NULL DEFAULT 'X-Event-Id' CHECK (event_id_header ~ '^[A-Za-z0-9-]{1,64}$'),
    replay_window_s  integer NOT NULL DEFAULT 300 CHECK (replay_window_s BETWEEN 30 AND 86400),
    max_attempts     integer NOT NULL DEFAULT 8 CHECK (max_attempts BETWEEN 1 AND 50),
    -- Free parameters for the mapping programs (paths, fields; never secrets).
    options          jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(options) = 'object'),
    -- P14: deliveries and webhooks run as this user (chosen by the administrator).
    run_as           text NOT NULL DEFAULT 'system' REFERENCES ana_system.app_user(username) ON UPDATE CASCADE,
    active           boolean NOT NULL DEFAULT true,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       text NOT NULL,
    CHECK (kind <> 'http_api' OR base_url IS NOT NULL),
    CHECK (auth <> 'oauth2_client' OR token_url IS NOT NULL)
);
CREATE INDEX connector_outbound_idx ON integration.connector (outbound_program);
CREATE INDEX connector_inbound_idx ON integration.connector (inbound_program);
CREATE INDEX connector_run_as_idx ON integration.connector (run_as);

-- RF-017-02: AES-256-GCM by the core; the database never sees the plain text.
CREATE TABLE integration.secret (
    connector  text NOT NULL REFERENCES integration.connector(name) ON DELETE CASCADE ON UPDATE CASCADE,
    key        text NOT NULL CHECK (key IN ('username', 'password', 'token', 'api_key', 'client_id',
                                            'client_secret', 'hmac_key')),
    ciphertext bytea NOT NULL,
    nonce      bytea NOT NULL CHECK (length(nonce) = 12),
    tag        bytea NOT NULL CHECK (length(tag) = 16),
    expires_at date,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by text NOT NULL,
    PRIMARY KEY (connector, key)
);

-- RF-017-05: transactional outbox and idempotent inbox.
CREATE TABLE integration.outbox (
    id           bigserial PRIMARY KEY,
    connector    text NOT NULL REFERENCES integration.connector(name) ON UPDATE CASCADE,
    kind         text NOT NULL CHECK (kind ~ '^[a-z][a-z0-9_.]{0,62}$'),
    ordering_key text,
    payload      jsonb NOT NULL,
    status       text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'done', 'dead', 'discarded')),
    attempts     integer NOT NULL DEFAULT 0,
    next_at      timestamptz NOT NULL DEFAULT now(),
    lease_until  timestamptz,
    last_error   text,
    result       jsonb,
    created_by   text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    done_at      timestamptz
);
CREATE INDEX outbox_due_idx ON integration.outbox (next_at) WHERE status IN ('pending', 'processing');
CREATE INDEX outbox_order_idx ON integration.outbox (connector, ordering_key, id)
    WHERE status IN ('pending', 'processing') AND ordering_key IS NOT NULL;
CREATE INDEX outbox_connector_status_idx ON integration.outbox (connector, status);
CREATE INDEX outbox_created_brin ON integration.outbox USING brin (created_at);

CREATE TABLE integration.inbox (
    id          bigserial PRIMARY KEY,
    connector   text NOT NULL REFERENCES integration.connector(name) ON UPDATE CASCADE,
    event_id    text NOT NULL CHECK (length(event_id) BETWEEN 1 AND 200),
    payload     jsonb NOT NULL,
    headers     jsonb NOT NULL DEFAULT '{}',
    status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'done', 'dead', 'discarded')),
    attempts    integer NOT NULL DEFAULT 0,
    next_at     timestamptz NOT NULL DEFAULT now(),
    lease_until timestamptz,
    last_error  text,
    result      jsonb,
    received_at timestamptz NOT NULL DEFAULT now(),
    done_at     timestamptz,
    UNIQUE (connector, event_id)
);
CREATE INDEX inbox_due_idx ON integration.inbox (next_at) WHERE status IN ('pending', 'processing');
CREATE INDEX inbox_connector_status_idx ON integration.inbox (connector, status);
CREATE INDEX inbox_received_brin ON integration.inbox USING brin (received_at);

CREATE TABLE integration.call_log (
    id         bigserial PRIMARY KEY,
    connector  text NOT NULL,
    method     text NOT NULL,
    path       text NOT NULL,
    status     integer,
    ms         integer NOT NULL,
    error      text,
    execution_id uuid,
    at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX call_log_connector_at_idx ON integration.call_log (connector, at);
CREATE INDEX call_log_at_brin ON integration.call_log USING brin (at);

-- The only way in for programs: same transaction as the business change (RF-017-05).
-- created_by is informational (the core sets ana.username per execution); deliveries run
-- as the connector's run_as, never as whoever enqueued.
CREATE FUNCTION integration.enqueue(p_connector text, p_kind text, p_payload jsonb, p_key text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_id bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM integration.connector WHERE name = p_connector AND active
                   AND outbound_program IS NOT NULL) THEN
        RAISE EXCEPTION 'CONNECTOR_NOT_FOUND: conector % inexistente, inativo ou sem programa de entrega', p_connector
            USING ERRCODE = 'check_violation';
    END IF;
    INSERT INTO integration.outbox (connector, kind, payload, ordering_key, created_by)
    VALUES (p_connector, p_kind, p_payload, p_key, COALESCE(NULLIF(current_setting('ana.username', true), ''), '?'))
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

-- ---------------------------------------------------------------- finance (RF-017-06..08)
INSERT INTO finance.account (code, description, nature, postable, cost_center_policy) VALUES
    ('5.2.1', 'Tarifas bancárias', 'expense', true, 'required'),
    ('4.2.1', 'Juros e multas recebidos', 'revenue', true, 'required')
ON CONFLICT DO NOTHING;
INSERT INTO finance.default_account (key, account, description) VALUES
    ('bank_fees', '5.2.1', 'Tarifas bancárias e de cobrança'),
    ('interest_received', '4.2.1', 'Juros e multas recebidos de clientes')
ON CONFLICT DO NOTHING;

CREATE TABLE finance.bank_account (
    code        text PRIMARY KEY CHECK (code ~ '^[A-Z0-9_-]{1,30}$'),
    name        text NOT NULL,
    account     text NOT NULL REFERENCES finance.account(code),
    bank        text,
    branch      text,
    number      text,
    active      boolean NOT NULL DEFAULT true
);
CREATE INDEX bank_account_account_idx ON finance.bank_account (account);
INSERT INTO finance.bank_account (code, name, account) VALUES ('CAIXA', 'Caixa e bancos', '1.1.1') ON CONFLICT DO NOTHING;

CREATE TABLE finance.bank_statement (
    id           bigserial PRIMARY KEY,
    bank_account text NOT NULL REFERENCES finance.bank_account(code) ON UPDATE CASCADE,
    source       text NOT NULL CHECK (source IN ('ofx', 'csv', 'cnab240', 'cnab400', 'api')),
    file_name    text,
    lines        integer NOT NULL DEFAULT 0,
    duplicates   integer NOT NULL DEFAULT 0,
    imported_by  text NOT NULL,
    imported_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX bank_statement_account_idx ON finance.bank_statement (bank_account);

CREATE TABLE finance.bank_statement_line (
    id           bigserial PRIMARY KEY,
    statement_id bigint NOT NULL REFERENCES finance.bank_statement(id),
    bank_account text NOT NULL REFERENCES finance.bank_account(code) ON UPDATE CASCADE,
    posted_on    date NOT NULL,
    amount       numeric(14,2) NOT NULL CHECK (amount <> 0),
    description  text NOT NULL DEFAULT '',
    document     text,
    dedup_key    text NOT NULL,
    status       text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'matched', 'ignored')),
    entry_id     bigint REFERENCES finance.journal_entry(id),
    matched_by   text,
    matched_at   timestamptz,
    UNIQUE (bank_account, dedup_key)
);
CREATE INDEX bank_statement_line_statement_idx ON finance.bank_statement_line (statement_id);
CREATE INDEX bank_statement_line_open_idx ON finance.bank_statement_line (bank_account, amount) WHERE status = 'open';
CREATE INDEX bank_statement_line_entry_idx ON finance.bank_statement_line (entry_id);

CREATE TABLE finance.bank_match (
    line_id  bigint NOT NULL REFERENCES finance.bank_statement_line(id) ON DELETE CASCADE,
    bill_id  bigint NOT NULL REFERENCES finance.bill(id),
    amount   numeric(14,2) NOT NULL,
    rule     text NOT NULL,
    PRIMARY KEY (line_id, bill_id)
);
CREATE INDEX bank_match_bill_idx ON finance.bank_match (bill_id);
CREATE INDEX bill_open_amount_idx ON finance.bill (kind, amount) WHERE status = 'open';

CREATE TABLE finance.charge (
    id             bigserial PRIMARY KEY,
    bill_id        bigint NOT NULL REFERENCES finance.bill(id),
    connector      text NOT NULL REFERENCES integration.connector(name) ON UPDATE CASCADE,
    method         text NOT NULL CHECK (method IN ('pix', 'boleto', 'card_link')),
    status         text NOT NULL DEFAULT 'requested'
                   CHECK (status IN ('requested', 'issued', 'paid', 'cancelled', 'failed')),
    external_id    text,
    qr_code        text,
    digitable_line text,
    url            text,
    amount         numeric(14,2) NOT NULL CHECK (amount > 0),
    fee            numeric(14,2) NOT NULL DEFAULT 0,
    paid_amount    numeric(14,2),
    paid_at        timestamptz,
    event_id       text,
    entry_id       bigint REFERENCES finance.journal_entry(id),
    created_by     text NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (connector, external_id)
);
CREATE INDEX charge_bill_idx ON finance.charge (bill_id);
CREATE INDEX charge_entry_idx ON finance.charge (entry_id);
CREATE UNIQUE INDEX charge_open_per_bill_uk ON finance.charge (bill_id) WHERE status IN ('requested', 'issued');

DO $$
BEGIN
    GRANT USAGE ON SCHEMA integration TO ana_exec, ana_read;
    -- The console reads connectors and messages; secrets stay out of every role but the core's.
    GRANT SELECT ON integration.connector, integration.outbox, integration.inbox, integration.call_log TO ana_read;
    REVOKE EXECUTE ON FUNCTION integration.enqueue(text, text, jsonb, text) FROM PUBLIC;
    GRANT EXECUTE ON FUNCTION integration.enqueue(text, text, jsonb, text) TO ana_exec;
    GRANT SELECT, INSERT, UPDATE, DELETE ON finance.bank_account, finance.bank_statement, finance.bank_statement_line,
        finance.bank_match, finance.charge TO ana_exec;
    GRANT USAGE, SELECT ON finance.bank_statement_id_seq, finance.bank_statement_line_id_seq, finance.charge_id_seq TO ana_exec;
    GRANT SELECT ON finance.bank_account, finance.bank_statement, finance.bank_statement_line, finance.bank_match,
        finance.charge TO ana_read;
END $$;
