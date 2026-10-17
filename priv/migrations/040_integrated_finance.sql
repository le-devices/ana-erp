-- 040 — Integrated processes, phases 2–4 (spec 038): exact settlements with residuals and credits,
-- automatic offsetting, complete statements (balance, posting rules, own transfers), gateway payouts,
-- invoice cancellation, supplier invoices by matching, returns to suppliers, labor cost of projects,
-- milestones tied to deliverables.

-- ---------------------------------------------------------------- accounts
INSERT INTO finance.account (code, description, nature, postable, cost_center_policy) VALUES
    ('1.1.6', 'Adiantamentos a fornecedores', 'asset', true, 'none'),
    ('1.1.7', 'Valores a receber do gateway de pagamento', 'asset', true, 'none'),
    ('1.1.8', 'Créditos com fornecedores (devoluções)', 'asset', true, 'none'),
    ('5.1.5', 'Variação de preço de compras', 'expense', true, 'required'),
    ('5.3.3', 'Mão de obra apropriada aos projetos', 'expense', true, 'required')
ON CONFLICT (code) DO NOTHING;
INSERT INTO finance.default_account (key, account, description) VALUES
    ('supplier_advances', '1.1.6', 'Pago a mais a fornecedores (a compensar)'),
    ('gateway_receivable', '1.1.7', 'Cobranças pagas no gateway ainda não repassadas'),
    ('supplier_credits', '1.1.8', 'Créditos por devolução a fornecedores'),
    ('purchase_price_variance', '5.1.5', 'Diferença entre a nota do fornecedor e o recebido'),
    ('labor_absorbed', '5.3.3', 'Crédito do custo das horas apropriadas aos projetos')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------- settlement policy (RF-038-05)
CREATE TABLE finance.settlement_policy (
    id          integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    tolerance   numeric(14,2) NOT NULL DEFAULT 1.00 CHECK (tolerance >= 0),      -- below it: fee or interest
    auto_offset boolean NOT NULL DEFAULT true,                                   -- credits offset open bills
    updated_by  text,
    updated_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO finance.settlement_policy (id) VALUES (1);

-- A partial payment leaves the rest open in a residual bill of the same document (never lost as a fee).
ALTER TABLE finance.bill ADD COLUMN parent_bill_id bigint REFERENCES finance.bill(id);
CREATE INDEX bill_parent_idx ON finance.bill (parent_bill_id) WHERE parent_bill_id IS NOT NULL;

CREATE TABLE finance.offset (
    id          bigserial PRIMARY KEY,
    party_id    integer NOT NULL REFERENCES base.party(id),
    credit_bill bigint NOT NULL REFERENCES finance.bill(id),
    debit_bill  bigint NOT NULL REFERENCES finance.bill(id),
    amount      numeric(14,2) NOT NULL CHECK (amount > 0),
    entry_id    bigint NOT NULL REFERENCES finance.journal_entry(id),
    created_by  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX offset_party_idx ON finance.offset (party_id, created_at DESC);

-- ---------------------------------------------------------------- statements (RF-038-06)
ALTER TABLE finance.bank_statement ADD COLUMN closing_balance numeric(14,2), ADD COLUMN closing_date date;
CREATE TABLE finance.statement_rule (
    id           serial PRIMARY KEY,
    bank_account text REFERENCES finance.bank_account(code) ON UPDATE CASCADE,  -- null: every account
    pattern      text NOT NULL CHECK (length(btrim(pattern)) >= 2),              -- found in description/document
    direction    text NOT NULL DEFAULT 'any' CHECK (direction IN ('in', 'out', 'any')),
    account      text NOT NULL REFERENCES finance.account(code),
    cost_center  text REFERENCES finance.cost_center(code) ON UPDATE CASCADE,
    memo         text NOT NULL DEFAULT '',
    priority     integer NOT NULL DEFAULT 100,
    active       boolean NOT NULL DEFAULT true,
    created_by   text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE finance.bank_statement_line ADD COLUMN rule text;

-- ---------------------------------------------------------------- gateway (RF-038-07)
ALTER TABLE finance.charge ADD COLUMN net numeric(14,2), ADD COLUMN payout_line_id bigint REFERENCES finance.bank_statement_line(id);
CREATE INDEX charge_payout_pending_idx ON finance.charge (connector, paid_at) WHERE status = 'paid' AND payout_line_id IS NULL;

-- ---------------------------------------------------------------- purchases (RF-038-10)
ALTER TABLE supply.policy
    ADD COLUMN supplier_invoice text NOT NULL DEFAULT 'receipt' CHECK (supplier_invoice IN ('receipt', 'match')),
    ADD COLUMN invoice_tolerance_pct numeric(5,2) NOT NULL DEFAULT 1.00 CHECK (invoice_tolerance_pct >= 0),
    ADD COLUMN invoice_tolerance_abs numeric(14,2) NOT NULL DEFAULT 5.00 CHECK (invoice_tolerance_abs >= 0);
CREATE TABLE supply.supplier_invoice (
    id          bigserial PRIMARY KEY,
    order_id    integer NOT NULL REFERENCES supply.purchase_order(id),
    supplier_id integer NOT NULL REFERENCES base.party(id),
    number      text NOT NULL CHECK (length(btrim(number)) >= 1),
    amount      numeric(14,2) NOT NULL CHECK (amount > 0),
    expected    numeric(14,2) NOT NULL,
    difference  numeric(14,2) NOT NULL,
    due_date    date NOT NULL,
    status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'rejected')),
    reason      text,
    receipts    bigint[] NOT NULL DEFAULT '{}',
    bill_id     bigint REFERENCES finance.bill(id),
    entry_id    bigint REFERENCES finance.journal_entry(id),
    created_by  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    decided_by  text,
    decided_at  timestamptz,
    UNIQUE (supplier_id, number)
);
ALTER TABLE supply.receipt ADD COLUMN invoice_id bigint REFERENCES supply.supplier_invoice(id);

-- Returns to suppliers leave at the purchase price and become a credit with the supplier.
ALTER TABLE inventory.stock_movement DROP CONSTRAINT stock_movement_reason_check;
ALTER TABLE inventory.stock_movement ADD CONSTRAINT stock_movement_reason_check CHECK (reason IN ('purchase', 'sale',
    'service_part', 'project_material', 'customer_return', 'adjustment_in', 'adjustment_out', 'loss', 'scrap',
    'production_issue', 'production_receipt', 'transfer', 'opening', 'purchase_return'));
INSERT INTO inventory.posting_rule (reason, label, counter_key) VALUES ('purchase_return', 'Devolução ao fornecedor', 'supplier_credits');
CREATE OR REPLACE FUNCTION inventory.movement_defaults() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.reason := COALESCE(NEW.reason, CASE WHEN NEW.quantity > 0 THEN 'adjustment_in' ELSE 'adjustment_out' END);
    IF NEW.quantity < 0 AND NEW.reason <> 'purchase_return' THEN
        NEW.unit_cost := NULL;     -- an outgoing movement leaves at the average (a return to the supplier: at its price)
    END IF;
    NEW.value := NULL;
    NEW.entry_id := NULL;
    RETURN NEW;
END $$;
-- The valuation honors the given cost of a return to the supplier.
CREATE OR REPLACE FUNCTION inventory.value_movements(p_ids bigint[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    m record;
    v_pid integer;
    v_qty numeric; v_val numeric; v_avg numeric;
    v_cost numeric; v_value numeric;
    ids bigint[] := '{}'; costs numeric[] := '{}'; vals numeric[] := '{}';
BEGIN
    FOR m IN SELECT id, product_id, quantity, reason, unit_cost FROM inventory.stock_movement
             WHERE id = ANY(p_ids) AND value IS NULL ORDER BY product_id, id LOOP
        IF v_pid IS DISTINCT FROM m.product_id THEN
            IF v_pid IS NOT NULL THEN
                UPDATE inventory.item_cost SET quantity = v_qty, value = v_val, avg_cost = v_avg, updated_at = now()
                 WHERE product_id = v_pid;
            END IF;
            v_pid := m.product_id;
            INSERT INTO inventory.item_cost (product_id) VALUES (v_pid) ON CONFLICT DO NOTHING;
            SELECT quantity, value, avg_cost INTO v_qty, v_val, v_avg FROM inventory.item_cost WHERE product_id = v_pid FOR UPDATE;
        END IF;
        IF m.reason = 'transfer' THEN
            v_cost := COALESCE(v_avg, inventory.fallback_cost(m.product_id));
            v_value := round(m.quantity * v_cost, 2);
        ELSIF m.quantity > 0 THEN
            v_cost := COALESCE(m.unit_cost, v_avg, inventory.fallback_cost(m.product_id));
            v_value := round(m.quantity * v_cost, 2);
            v_qty := v_qty + m.quantity;
            v_val := v_val + v_value;
            v_avg := CASE WHEN v_qty > 0 THEN round(v_val / v_qty, 6) ELSE COALESCE(v_avg, v_cost) END;
        ELSE
            v_cost := COALESCE(CASE WHEN m.reason = 'purchase_return' THEN m.unit_cost END, v_avg,
                               inventory.fallback_cost(m.product_id));
            v_value := CASE WHEN v_qty + m.quantity = 0 THEN -v_val ELSE round(m.quantity * v_cost, 2) END;
            v_qty := v_qty + m.quantity;
            v_val := v_val + v_value;
            v_avg := CASE WHEN m.reason = 'purchase_return' AND v_qty > 0 THEN round(v_val / v_qty, 6) ELSE COALESCE(v_avg, v_cost) END;
        END IF;
        ids := ids || m.id; costs := costs || round(v_cost, 6); vals := vals || v_value;
    END LOOP;
    IF v_pid IS NOT NULL THEN
        UPDATE inventory.item_cost SET quantity = v_qty, value = v_val, avg_cost = v_avg, updated_at = now() WHERE product_id = v_pid;
        UPDATE inventory.stock_movement s SET unit_cost = x.c, value = x.v
          FROM unnest(ids, costs, vals) AS x(id, c, v) WHERE s.id = x.id;
    END IF;
END $$;

-- ---------------------------------------------------------------- projects (RF-038-11, 12)
ALTER TABLE projects.time_entry ADD COLUMN labor_entry_id bigint REFERENCES finance.journal_entry(id);
CREATE INDEX time_entry_labor_pending_idx ON projects.time_entry (entry_date) WHERE status IN ('approved', 'invoiced') AND labor_entry_id IS NULL;
ALTER TABLE projects.milestone ADD COLUMN task_id integer REFERENCES projects.task(id);

-- ---------------------------------------------------------------- reconciliation, extended (RF-038-04)
CREATE OR REPLACE FUNCTION finance.reconciliation()
RETURNS TABLE (key text, label text, account text, subledger numeric, ledger numeric, difference numeric, items bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    WITH bal AS (
        SELECT l.account, sum(l.debit - l.credit) AS d FROM finance.journal_line l GROUP BY l.account
    ), ctl AS (
        SELECT b.account, sum(b.amount) AS open_amount, count(*) AS n FROM finance.bill b WHERE b.status = 'open' GROUP BY b.account
    ), keys AS (
        SELECT d.key, d.account, a.nature FROM finance.default_account d JOIN finance.account a ON a.code = d.account
         WHERE d.key IN ('customers', 'suppliers', 'customer_credits', 'supplier_credits', 'supplier_advances')
    ), wip AS (
        SELECT COALESCE(sum(-m.value), 0) AS issued
          FROM inventory.stock_movement m JOIN production.work_order o ON m.document = 'OP-' || o.number
         WHERE m.reason = 'production_issue' AND o.status <> 'closed'
    ), wip_hours AS (
        SELECT COALESCE(sum(r.cost), 0) AS hours
          FROM production.operation_report r JOIN production.work_order o ON o.id = r.order_id WHERE o.status <> 'closed'
    ), wip_out AS (
        SELECT COALESCE(sum(m.value), 0) AS delivered
          FROM inventory.stock_movement m JOIN production.work_order o ON m.document = 'OP-' || o.number
         WHERE m.reason = 'production_receipt' AND o.status <> 'closed'
    ), banks AS (
        SELECT ba.code, ba.name, ba.account, s.closing_balance, s.closing_date
          FROM finance.bank_account ba
          JOIN LATERAL (SELECT closing_balance, closing_date FROM finance.bank_statement st
                         WHERE st.bank_account = ba.code AND st.closing_balance IS NOT NULL
                         ORDER BY st.closing_date DESC, st.id DESC LIMIT 1) s ON true
         -- Only a ledger account of its own can be compared with one statement.
         WHERE ba.active AND NOT EXISTS (SELECT 1 FROM finance.bank_account o WHERE o.account = ba.account AND o.code <> ba.code AND o.active)
    )
    SELECT k.key,
           CASE k.key WHEN 'customers' THEN 'Clientes (títulos a receber)' WHEN 'suppliers' THEN 'Fornecedores (títulos a pagar)'
                      WHEN 'customer_credits' THEN 'Créditos de clientes' WHEN 'supplier_credits' THEN 'Créditos com fornecedores'
                      ELSE 'Adiantamentos a fornecedores' END,
           k.account, COALESCE(c.open_amount, 0),
           COALESCE(CASE WHEN k.nature = 'asset' THEN b.d ELSE -b.d END, 0),
           COALESCE(c.open_amount, 0) - COALESCE(CASE WHEN k.nature = 'asset' THEN b.d ELSE -b.d END, 0),
           COALESCE(c.n, 0)
      FROM keys k LEFT JOIN ctl c ON c.account = k.account LEFT JOIN bal b ON b.account = k.account
    UNION ALL
    SELECT 'inventory', 'Estoque (valor × conta)', finance.account_for('inventory'),
           (SELECT COALESCE(sum(value), 0) FROM inventory.item_cost),
           COALESCE((SELECT d FROM bal WHERE account = finance.account_for('inventory')), 0),
           (SELECT COALESCE(sum(value), 0) FROM inventory.item_cost)
             - COALESCE((SELECT d FROM bal WHERE account = finance.account_for('inventory')), 0),
           (SELECT count(*) FROM inventory.item_cost WHERE quantity <> 0)
    UNION ALL
    SELECT 'goods_received', 'Recebimentos a faturar', finance.account_for('goods_received'),
           x.v, COALESCE(-(SELECT d FROM bal WHERE account = finance.account_for('goods_received')), 0),
           x.v - COALESCE(-(SELECT d FROM bal WHERE account = finance.account_for('goods_received')), 0), x.n
      FROM (SELECT COALESCE(sum(r.total), 0) AS v, count(*) AS n FROM supply.receipt r
             WHERE r.bill_id IS NULL AND r.total > 0) x      -- a pending invoice still owes it
    UNION ALL
    SELECT 'gateway_receivable', 'Valores a receber do gateway', finance.account_for('gateway_receivable'),
           x.v, COALESCE((SELECT d FROM bal WHERE account = finance.account_for('gateway_receivable')), 0),
           x.v - COALESCE((SELECT d FROM bal WHERE account = finance.account_for('gateway_receivable')), 0), x.n
      FROM (SELECT COALESCE(sum(net), 0) AS v, count(*) AS n FROM finance.charge
             WHERE status = 'paid' AND net IS NOT NULL AND payout_line_id IS NULL AND entry_id IS NOT NULL) x
    UNION ALL
    SELECT 'work_in_process', 'Produtos em elaboração (ordens abertas)', finance.account_for('work_in_process'),
           wip.issued + wip_hours.hours - wip_out.delivered,
           COALESCE((SELECT d FROM bal WHERE account = finance.account_for('work_in_process')), 0),
           wip.issued + wip_hours.hours - wip_out.delivered
             - COALESCE((SELECT d FROM bal WHERE account = finance.account_for('work_in_process')), 0),
           (SELECT count(*) FROM production.work_order WHERE status NOT IN ('closed', 'cancelled', 'planned'))
      FROM wip, wip_hours, wip_out
    UNION ALL
    -- Bank: the statement's balance minus what is still open in it, against the ledger on the same date.
    SELECT 'bank:' || bk.code, 'Banco ' || bk.name || ' (extrato em ' || to_char(bk.closing_date, 'DD/MM/YYYY') || ')', bk.account,
           bk.closing_balance - COALESCE((SELECT sum(l.amount) FROM finance.bank_statement_line l WHERE l.bank_account = bk.code
                                           AND l.status = 'open' AND l.posted_on <= bk.closing_date), 0),
           COALESCE((SELECT sum(jl.debit - jl.credit) FROM finance.journal_line jl JOIN finance.journal_entry je ON je.id = jl.entry_id
                      WHERE jl.account = bk.account AND je.entry_date <= bk.closing_date), 0),
           bk.closing_balance - COALESCE((SELECT sum(l.amount) FROM finance.bank_statement_line l WHERE l.bank_account = bk.code
                                           AND l.status = 'open' AND l.posted_on <= bk.closing_date), 0)
             - COALESCE((SELECT sum(jl.debit - jl.credit) FROM finance.journal_line jl JOIN finance.journal_entry je ON je.id = jl.entry_id
                         WHERE jl.account = bk.account AND je.entry_date <= bk.closing_date), 0),
           (SELECT count(*) FROM finance.bank_statement_line l WHERE l.bank_account = bk.code AND l.status = 'open')
      FROM banks bk
    UNION ALL
    SELECT 'bills_without_entry', 'Títulos sem lançamento', NULL, NULL, NULL, COALESCE(sum(amount), 0), count(*)
      FROM finance.bill WHERE entry_id IS NULL AND status <> 'cancelled'
    UNION ALL
    SELECT 'movements_without_entry', 'Movimentações de estoque valorizadas sem lançamento', NULL, NULL, NULL,
           COALESCE(sum(m.value), 0), count(*)
      FROM inventory.stock_movement m JOIN inventory.posting_rule r ON r.reason = m.reason
     WHERE r.counter_key IS NOT NULL AND m.entry_id IS NULL AND m.value <> 0
       AND m.created_at > (SELECT COALESCE(max(applied_at), now()) FROM ana_system.migration WHERE name = '037_inventory_valuation')
    UNION ALL
    SELECT 'freight_without_bill', 'Fretes de expedição sem título da transportadora', NULL, NULL, NULL,
           COALESCE(sum(s.freight_cost), 0), count(*)
      FROM logistics.shipment s
     WHERE s.freight_cost > 0 AND s.freight_bill_id IS NULL AND s.status NOT IN ('cancelled')
       AND s.created_at > (SELECT COALESCE(max(applied_at), now()) FROM ana_system.migration WHERE name = '037_inventory_valuation')
$$;

-- ---------------------------------------------------------------- invoice cancellation of a service order (RF-038-08)
-- An invoiced order goes back to "done" only through field.cancel_invoice, which marks its transaction.
CREATE OR REPLACE FUNCTION field.order_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_cancel boolean := OLD.status = 'invoiced' AND NEW.status = 'done'
                        AND current_setting('ana.invoice_cancel', true) = OLD.number::text;
BEGIN
    IF NEW.status <> OLD.status AND NOT v_cancel AND NOT ((OLD.status, NEW.status) IN (
        ('open', 'scheduled'), ('open', 'cancelled'), ('open', 'en_route'), ('open', 'in_progress'),
        ('scheduled', 'en_route'), ('scheduled', 'in_progress'), ('scheduled', 'cancelled'), ('scheduled', 'open'),
        ('en_route', 'in_progress'), ('in_progress', 'done'), ('done', 'invoiced'))) THEN
        RAISE EXCEPTION 'INVALID_STATE: OS % não pode passar de % para %', OLD.number, OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status IN ('invoiced', 'cancelled') AND NOT v_cancel THEN
        RAISE EXCEPTION 'ORDER_CLOSED: OS % está %', OLD.number, OLD.status USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

-- ---------------------------------------------------------------- project facts for the BPM (RF-038-12)
INSERT INTO bpm.fact (code, entity, name, sql) VALUES
    ('project.to_invoice', 'project', 'Há o que faturar (marco concluído, horas aprovadas ou despesa refaturável)',
     'SELECT EXISTS (SELECT 1 FROM projects.project p WHERE p.code = $1 AND ('
     ' EXISTS (SELECT 1 FROM projects.milestone m WHERE m.project_id = p.id AND m.status = ''completed'')'
     ' OR EXISTS (SELECT 1 FROM projects.time_entry t WHERE t.project_id = p.id AND t.status = ''approved'' AND t.billable)'
     ' OR EXISTS (SELECT 1 FROM projects.expense e WHERE e.project_id = p.id AND e.status = ''posted'' AND e.rebillable)))'),
    ('project.closed', 'project', 'Projeto encerrado',
     'SELECT status = ''closed'' FROM projects.project WHERE code = $1')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------- grants
GRANT SELECT ON finance.settlement_policy, finance.offset, finance.statement_rule, supply.supplier_invoice TO ana_exec, ana_read;
GRANT UPDATE (tolerance, auto_offset, updated_by, updated_at) ON finance.settlement_policy TO ana_exec;
GRANT INSERT ON finance.offset, supply.supplier_invoice TO ana_exec;
GRANT UPDATE (status, reason, bill_id, entry_id, decided_by, decided_at) ON supply.supplier_invoice TO ana_exec;
GRANT INSERT, UPDATE, DELETE ON finance.statement_rule TO ana_exec;
GRANT USAGE ON SEQUENCE finance.offset_id_seq, finance.statement_rule_id_seq, supply.supplier_invoice_id_seq TO ana_exec;
