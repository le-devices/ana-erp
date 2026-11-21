-- 031 — Automated flows: sale → shipment → invoice → charge → receipt, and others (spec 030)
--
-- The catalog (flows, steps, the SQL that reads a document's facts and tells whether a step is
-- done) belongs to the product (P13); an installation only switches flows on, chooses per step
-- automatic or manual, conditions and the robot that runs it. A flow starts in the same
-- transaction that creates its document (trigger); the core's engine runs the automatic steps.

CREATE SCHEMA flow;

CREATE TABLE flow.definition (
    code        text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,40}$'),
    name        text NOT NULL,
    description text NOT NULL DEFAULT '',
    document    text NOT NULL,                       -- what one instance follows, e.g. "pedido de venda"
    facts_sql   text NOT NULL,                       -- $1 = document key (text) → one row of facts
    cancel_sql  text,                                -- $1 → true when the document was cancelled
    open_sql    text NOT NULL,                       -- keys of documents still open (to include on activation)
    active      boolean NOT NULL DEFAULT false,      -- off out of the box: nothing changes until the owner decides
    run_as      text NOT NULL DEFAULT 'system' REFERENCES ana_system.app_user(username) ON UPDATE CASCADE,
    updated_by  text,
    updated_at  timestamptz
);

CREATE TABLE flow.step (
    flow_code    text NOT NULL REFERENCES flow.definition(code) ON DELETE CASCADE,
    seq          integer NOT NULL CHECK (seq > 0),
    code         text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]{1,40}$'),
    name         text NOT NULL,
    program      text,                               -- null: waits for an outside event (programs are seeded after migrations)
    params       jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(params) = 'object'),
    done_sql     text NOT NULL,                      -- $1 → true when the step is done (by the flow or by anyone)
    mode         text NOT NULL DEFAULT 'manual' CHECK (mode IN ('auto', 'manual', 'wait')),
    condition    jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(condition) = 'array'),
    max_attempts integer NOT NULL DEFAULT 5 CHECK (max_attempts BETWEEN 1 AND 50),
    PRIMARY KEY (flow_code, seq),
    UNIQUE (flow_code, code),
    CHECK ((mode = 'wait') = (program IS NULL))
);

CREATE TABLE flow.instance (
    id          bigserial PRIMARY KEY,
    flow_code   text NOT NULL REFERENCES flow.definition(code),
    doc_key     text NOT NULL,
    status      text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'waiting', 'failed', 'done', 'cancelled')),
    current_seq integer,
    facts       jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    UNIQUE (flow_code, doc_key)
);
CREATE INDEX instance_open_idx ON flow.instance (flow_code, status) WHERE status IN ('running', 'waiting', 'failed');
CREATE INDEX instance_finished_brin ON flow.instance USING brin (finished_at);

CREATE TABLE flow.instance_step (
    instance_id   bigint NOT NULL REFERENCES flow.instance(id) ON DELETE CASCADE,
    seq           integer NOT NULL,
    status        text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'ready', 'running', 'waiting', 'done', 'failed', 'skipped', 'cancelled')),
    attempts      integer NOT NULL DEFAULT 0,
    next_at       timestamptz,
    lease_until   timestamptz,
    force         boolean NOT NULL DEFAULT false,    -- someone asked to run it now (as themselves)
    requested_by  text,
    execution_id  uuid,
    result        jsonb,
    error         jsonb,
    how           text CHECK (how IN ('auto', 'manual', 'outside', 'skipped')),
    done_by       text,
    reason        text,
    started_at    timestamptz,
    finished_at   timestamptz,
    PRIMARY KEY (instance_id, seq)
);
CREATE INDEX instance_step_due_idx ON flow.instance_step (next_at) WHERE status = 'ready';
CREATE INDEX instance_step_waiting_idx ON flow.instance_step (instance_id) WHERE status IN ('waiting', 'failed');

-- ---------------------------------------------------------------- functions (run as the core)

-- RF-030-03: starts a flow for a document, in the caller's transaction (only when switched on).
CREATE FUNCTION flow.start(p_flow text, p_key text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_id bigint;
    v_first integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM flow.definition WHERE code = p_flow AND active) THEN
        RETURN NULL;
    END IF;
    INSERT INTO flow.instance (flow_code, doc_key) VALUES (p_flow, p_key) ON CONFLICT DO NOTHING RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT min(seq) INTO v_first FROM flow.step WHERE flow_code = p_flow;
    INSERT INTO flow.instance_step (instance_id, seq, status, next_at)
    SELECT v_id, s.seq, CASE WHEN s.seq = v_first THEN 'ready' ELSE 'pending' END,
           CASE WHEN s.seq = v_first THEN now() END
    FROM flow.step s WHERE s.flow_code = p_flow;
    UPDATE flow.instance SET current_seq = v_first WHERE id = v_id;
    PERFORM pg_notify('ana_flow', v_id::text);
    RETURN v_id;
END $$;

-- Trigger: flow.start_trigger('<flow>', '<key column>').
CREATE FUNCTION flow.start_trigger() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    PERFORM flow.start(TG_ARGV[0], to_jsonb(NEW) ->> TG_ARGV[1]);
    RETURN NULL;
END $$;

-- Next pending step becomes ready; none left → the instance is done.
CREATE FUNCTION flow.advance(p_instance bigint, p_seq integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_next integer;
BEGIN
    SELECT min(seq) INTO v_next FROM flow.instance_step WHERE instance_id = p_instance AND seq > p_seq AND status = 'pending';
    IF v_next IS NULL THEN
        UPDATE flow.instance SET status = 'done', current_seq = p_seq, updated_at = now(), finished_at = now()
        WHERE id = p_instance AND status <> 'cancelled';
    ELSE
        UPDATE flow.instance_step SET status = 'ready', next_at = now() WHERE instance_id = p_instance AND seq = v_next;
        UPDATE flow.instance SET status = 'running', current_seq = v_next, updated_at = now() WHERE id = p_instance;
        PERFORM pg_notify('ana_flow', p_instance::text);
    END IF;
END $$;

-- RF-030-05: a person skips a step (reason required) — the following steps continue.
CREATE FUNCTION flow.skip(p_instance bigint, p_seq integer, p_user text, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF length(coalesce(trim(p_reason), '')) < 3 THEN
        RAISE EXCEPTION 'INVALID_PARAMETER: informe o motivo para pular a etapa' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE flow.instance_step SET status = 'skipped', how = 'skipped', done_by = p_user, reason = p_reason, finished_at = now()
    WHERE instance_id = p_instance AND seq = p_seq AND status IN ('ready', 'waiting', 'failed');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_STATE: a etapa não está aguardando nem com falha' USING ERRCODE = 'check_violation';
    END IF;
    PERFORM flow.advance(p_instance, p_seq);
END $$;

-- RF-030-05: reprocess a failed step, or run a waiting one now (p_force: runs as p_user even when manual).
CREATE FUNCTION flow.retry(p_instance bigint, p_seq integer, p_user text, p_force boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    UPDATE flow.instance_step SET status = 'ready', next_at = now(), attempts = 0, force = p_force, requested_by = p_user,
           error = NULL, lease_until = NULL
    WHERE instance_id = p_instance AND seq = p_seq AND status IN ('waiting', 'failed');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_STATE: a etapa não está aguardando nem com falha' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE flow.instance SET status = 'running', updated_at = now() WHERE id = p_instance;
    PERFORM pg_notify('ana_flow', p_instance::text);
END $$;

-- Switching a flow on can bring the documents already open (one instance each).
CREATE FUNCTION flow.include_open(p_flow text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_sql text;
    v_n integer := 0;
    v_key text;
BEGIN
    SELECT open_sql INTO v_sql FROM flow.definition WHERE code = p_flow AND active;
    IF v_sql IS NULL THEN
        RAISE EXCEPTION 'INVALID_STATE: ligue a esteira antes de incluir os documentos em aberto' USING ERRCODE = 'check_violation';
    END IF;
    FOR v_key IN EXECUTE v_sql LOOP
        IF flow.start(p_flow, v_key) IS NOT NULL THEN
            v_n := v_n + 1;
        END IF;
    END LOOP;
    RETURN v_n;
END $$;

GRANT USAGE ON SCHEMA flow TO ana_exec, ana_read;
GRANT SELECT ON ALL TABLES IN SCHEMA flow TO ana_exec, ana_read;
-- Programs configure the flows (role checked by the program) and act through the functions above.
GRANT UPDATE (active, run_as, updated_by, updated_at) ON flow.definition TO ana_exec;
GRANT UPDATE (mode, condition, max_attempts) ON flow.step TO ana_exec;
REVOKE ALL ON FUNCTION flow.advance(bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION flow.skip(bigint, integer, text, text), flow.retry(bigint, integer, text, boolean),
                          flow.include_open(text), flow.start(text, text) TO ana_exec;

-- Shipping on its own needs a carrier: the default one (logistics.save_carrier marks it).
ALTER TABLE logistics.policy ADD COLUMN default_carrier integer REFERENCES logistics.carrier(id) ON DELETE SET NULL;

-- ---------------------------------------------------------------- product catalog

INSERT INTO flow.definition (code, name, description, document, facts_sql, cancel_sql, open_sql) VALUES
('sales', 'Venda', 'Pedido → expedição (baixa e movimentação do estoque) → faturamento → cobrança → recebimento', 'pedido de venda',
 $q$SELECT o.number, o.total, o.customer_id, p.name AS customer, o.payment_term, t.method AS payment_method,
           w.code AS warehouse, o.status
    FROM sales.sales_order o JOIN base.party p ON p.id = o.customer_id JOIN inventory.warehouse w ON w.id = o.warehouse_id
    LEFT JOIN finance.payment_term t ON t.code = o.payment_term WHERE o.number = $1::bigint$q$,
 $q$SELECT status = 'CANCELLED' FROM sales.sales_order WHERE number = $1::bigint$q$,
 $q$SELECT number::text FROM sales.sales_order WHERE status = 'OPEN' ORDER BY number$q$),
('purchase', 'Compras', 'Solicitação → aprovação → ordem ao fornecedor → recebimento → pagamento', 'solicitação de compra',
 $q$SELECT r.number, r.total, r.status, r.origin, r.requester, w.code AS warehouse,
           (SELECT min(po.number) FROM supply.purchase_order_line l JOIN supply.purchase_order po ON po.id = l.order_id
            WHERE l.request_id = r.id) AS purchase_order
    FROM supply.purchase_request r JOIN inventory.warehouse w ON w.id = r.warehouse_id WHERE r.number = $1::bigint$q$,
 $q$SELECT status IN ('rejected', 'cancelled') FROM supply.purchase_request WHERE number = $1::bigint$q$,
 $q$SELECT number::text FROM supply.purchase_request WHERE status IN ('draft', 'submitted', 'approved') ORDER BY number$q$),
('field', 'Serviço em campo', 'Chamado → agendamento → execução e aceite → faturamento → cobrança → recebimento', 'ordem de serviço',
 $q$SELECT o.number, o.status, o.priority, o.customer_id, p.name AS customer, o.project_id IS NOT NULL AS project
    FROM field.service_order o JOIN base.party p ON p.id = o.customer_id WHERE o.number = $1::bigint$q$,
 $q$SELECT status = 'cancelled' FROM field.service_order WHERE number = $1::bigint$q$,
 $q$SELECT number::text FROM field.service_order WHERE status NOT IN ('invoiced', 'cancelled') ORDER BY number$q$),
('production', 'Produção', 'Ordem planejada → liberação → requisição dos componentes → fabricação → encerramento', 'ordem de produção',
 $q$SELECT o.number, o.status, p.code AS product, o.quantity, o.due_date
    FROM production.work_order o JOIN base.product p ON p.id = o.product_id WHERE o.number = $1::bigint$q$,
 $q$SELECT status = 'cancelled' FROM production.work_order WHERE number = $1::bigint$q$,
 $q$SELECT number::text FROM production.work_order WHERE status NOT IN ('closed', 'cancelled') ORDER BY number$q$);

-- Bills of a document: "ORD-12" or its installments "ORD-12/1", "ORD-12/2"…
CREATE FUNCTION flow.document_bills(p_document text) RETURNS SETOF finance.bill
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS
$$ SELECT * FROM finance.bill WHERE kind = 'receivable' AND (document = p_document OR document LIKE p_document || '/%') $$;

INSERT INTO flow.step (flow_code, seq, code, name, program, params, mode, done_sql) VALUES
('sales', 1, 'ship', 'Expedição', 'logistics.ship', '{"order": "{{number}}"}', 'manual',
 $q$SELECT NOT EXISTS (
      SELECT 1 FROM sales.sales_order o JOIN sales.sales_order_item i ON i.order_id = o.id
      JOIN base.product p ON p.id = i.product_id AND p.kind = 'goods'
      WHERE o.number = $1::bigint AND i.quantity > COALESCE((
        SELECT sum(l.quantity) FROM logistics.shipment_line l JOIN logistics.shipment s ON s.id = l.shipment_id
        WHERE s.sales_order_id = o.id AND l.order_line = i.line AND s.status NOT IN ('cancelled', 'returned')), 0))$q$),
('sales', 2, 'invoice', 'Faturamento', 'sales.invoice_order', '{"number": "{{number}}"}', 'manual',
 $q$SELECT status = 'INVOICED' FROM sales.sales_order WHERE number = $1::bigint$q$),
('sales', 3, 'charge', 'Cobrança', 'finance.charge_document', '{"document": "ORD-{{number}}"}', 'auto',
 $q$SELECT EXISTS (SELECT 1 FROM flow.document_bills('ORD-' || $1)) AND NOT EXISTS (
      SELECT 1 FROM flow.document_bills('ORD-' || $1) b JOIN finance.payment_term t ON t.code = b.payment_term
      WHERE b.status = 'open' AND t.connector IS NOT NULL AND t.method IN ('pix', 'boleto', 'credit_card')
        AND NOT EXISTS (SELECT 1 FROM finance.charge c WHERE c.bill_id = b.id AND c.status NOT IN ('cancelled', 'failed')))$q$),
('sales', 4, 'receipt', 'Recebimento', NULL, '{}', 'wait',
 $q$SELECT EXISTS (SELECT 1 FROM flow.document_bills('ORD-' || $1))
       AND NOT EXISTS (SELECT 1 FROM flow.document_bills('ORD-' || $1) WHERE status = 'open')$q$),

('purchase', 1, 'approve', 'Aprovação', 'supply.approve_request', '{"request": "{{number}}"}', 'manual',
 $q$SELECT status IN ('approved', 'ordered') FROM supply.purchase_request WHERE number = $1::bigint$q$),
('purchase', 2, 'order', 'Ordem ao fornecedor', 'supply.create_orders', '{"requests": ["{{number}}"]}', 'auto',
 $q$SELECT EXISTS (SELECT 1 FROM supply.purchase_order_line l JOIN supply.purchase_request r ON r.id = l.request_id
                   WHERE r.number = $1::bigint)$q$),
('purchase', 3, 'receive', 'Recebimento', 'supply.receive', '{"order": "{{purchase_order}}"}', 'manual',
 $q$SELECT EXISTS (SELECT 1 FROM supply.purchase_order_line l JOIN supply.purchase_request r ON r.id = l.request_id
                   WHERE r.number = $1::bigint)
       AND NOT EXISTS (SELECT 1 FROM supply.purchase_order_line l JOIN supply.purchase_request r ON r.id = l.request_id
                       WHERE r.number = $1::bigint AND l.received_qty < l.quantity)$q$),
('purchase', 4, 'payment', 'Pagamento', NULL, '{}', 'wait',
 $q$SELECT NOT EXISTS (
      SELECT 1 FROM supply.purchase_order_line l JOIN supply.purchase_request r ON r.id = l.request_id
      JOIN supply.receipt rc ON rc.order_id = l.order_id JOIN finance.bill b ON b.id = rc.bill_id
      WHERE r.number = $1::bigint AND b.status = 'open')$q$),

('field', 1, 'schedule', 'Agendamento', 'field.schedule', '{"order": "{{number}}"}', 'manual',
 $q$SELECT status <> 'open' FROM field.service_order WHERE number = $1::bigint$q$),
('field', 2, 'execute', 'Execução e aceite', NULL, '{}', 'wait',
 $q$SELECT status IN ('done', 'invoiced') FROM field.service_order WHERE number = $1::bigint$q$),
('field', 3, 'invoice', 'Faturamento', 'field.invoice_orders', '{"orders": ["{{number}}"]}', 'manual',
 $q$SELECT status = 'invoiced' FROM field.service_order WHERE number = $1::bigint$q$),
('field', 4, 'charge', 'Cobrança', 'finance.charge_document', '{"document": "OS-{{number}}"}', 'auto',
 $q$SELECT NOT EXISTS (
      SELECT 1 FROM flow.document_bills('OS-' || $1) b JOIN finance.payment_term t ON t.code = b.payment_term
      WHERE b.status = 'open' AND t.connector IS NOT NULL AND t.method IN ('pix', 'boleto', 'credit_card')
        AND NOT EXISTS (SELECT 1 FROM finance.charge c WHERE c.bill_id = b.id AND c.status NOT IN ('cancelled', 'failed')))$q$),
('field', 5, 'receipt', 'Recebimento', NULL, '{}', 'wait',
 $q$SELECT NOT EXISTS (SELECT 1 FROM flow.document_bills('OS-' || $1) WHERE status = 'open')$q$),

('production', 1, 'release', 'Liberação', 'production.release_order', '{"order": "{{number}}"}', 'manual',
 $q$SELECT status <> 'planned' FROM production.work_order WHERE number = $1::bigint$q$),
('production', 2, 'issue', 'Requisição dos componentes', 'production.issue_components', '{"order": "{{number}}"}', 'auto',
 $q$SELECT NOT EXISTS (SELECT 1 FROM production.order_component c JOIN production.work_order o ON o.id = c.order_id
                       WHERE o.number = $1::bigint AND c.issued_qty < c.qty_required)$q$),
('production', 3, 'make', 'Fabricação', NULL, '{}', 'wait',
 $q$SELECT status IN ('completed', 'closed') FROM production.work_order WHERE number = $1::bigint$q$),
('production', 4, 'close', 'Encerramento', 'production.close_order', '{"order": "{{number}}"}', 'manual',
 $q$SELECT status = 'closed' FROM production.work_order WHERE number = $1::bigint$q$);

CREATE TRIGGER sales_order_flow AFTER INSERT ON sales.sales_order
    FOR EACH ROW EXECUTE FUNCTION flow.start_trigger('sales', 'number');
CREATE TRIGGER purchase_request_flow AFTER INSERT ON supply.purchase_request
    FOR EACH ROW EXECUTE FUNCTION flow.start_trigger('purchase', 'number');
CREATE TRIGGER service_order_flow AFTER INSERT ON field.service_order
    FOR EACH ROW EXECUTE FUNCTION flow.start_trigger('field', 'number');
CREATE TRIGGER work_order_flow AFTER INSERT ON production.work_order
    FOR EACH ROW EXECUTE FUNCTION flow.start_trigger('production', 'number');
