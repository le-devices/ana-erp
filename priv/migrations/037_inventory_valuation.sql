-- 037 — Integrated processes, phase 1 (spec 038): valued stock with automatic accounting,
-- control account of bills, period close and automatic reconciliation of subledgers.

-- ---------------------------------------------------------------- accounts (RF-038-01, 03)
INSERT INTO finance.account (code, description, nature, postable, cost_center_policy) VALUES
    ('2.1.3', 'Recebimentos a faturar', 'liability', true, 'none'),
    ('3.1.2', 'Saldos de abertura', 'equity', true, 'none'),
    ('4.1.3', 'Receita de frete', 'revenue', true, 'required'),
    ('4.3.1', 'Ganhos de estoque', 'revenue', true, 'required'),
    ('5.1.4', 'Fretes sobre vendas', 'expense', true, 'required'),
    ('5.3.2', 'Variação de produção', 'expense', true, 'required'),
    ('5.4.1', 'Perdas de estoque', 'expense', true, 'required')
ON CONFLICT (code) DO NOTHING;

INSERT INTO finance.default_account (key, account, description) VALUES
    ('cogs', '5.1.1', 'Custo das mercadorias vendidas'),
    ('goods_received', '2.1.3', 'Mercadorias recebidas ainda sem nota/título do fornecedor'),
    ('opening_balances', '3.1.2', 'Contrapartida de saldos de abertura'),
    ('freight_revenue', '4.1.3', 'Frete cobrado do cliente'),
    ('inventory_gains', '4.3.1', 'Sobras de estoque (contagem e ajustes)'),
    ('freight_expense', '5.1.4', 'Frete pago às transportadoras nas vendas'),
    ('production_variance', '5.3.2', 'Diferença entre custo real e padrão das ordens de produção'),
    ('inventory_losses', '5.4.1', 'Perdas, descartes e faltas de estoque')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------- valued movements (RF-038-01)
ALTER TABLE inventory.stock_movement
    ADD COLUMN reason text CHECK (reason IN ('purchase', 'sale', 'service_part', 'project_material', 'customer_return',
        'adjustment_in', 'adjustment_out', 'loss', 'scrap', 'production_issue', 'production_receipt', 'transfer', 'opening')),
    ADD COLUMN unit_cost numeric(18,6) CHECK (unit_cost >= 0),
    ADD COLUMN value numeric(14,2),
    ADD COLUMN entry_id bigint REFERENCES finance.journal_entry(id);
CREATE INDEX stock_movement_entry_idx ON inventory.stock_movement (entry_id);
COMMENT ON COLUMN inventory.stock_movement.value IS 'Quantidade × custo (negativo nas saídas); calculado pelo banco (spec 038)';

-- Own stock of the company: quantity, value and moving weighted average cost per item.
-- Transfers do not change it (goods in transit still belong to the company).
CREATE TABLE inventory.item_cost (
    product_id integer PRIMARY KEY REFERENCES base.product(id),
    quantity   numeric(14,3) NOT NULL DEFAULT 0,
    value      numeric(14,2) NOT NULL DEFAULT 0,
    avg_cost   numeric(18,6),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- How each reason is accounted: stock up = D inventory / C counter; stock down = D counter / C inventory.
-- counter_key NULL = no entry (transfers). Adjustable per client (P13).
CREATE TABLE inventory.posting_rule (
    reason      text PRIMARY KEY,
    label       text NOT NULL,
    counter_key text
);
INSERT INTO inventory.posting_rule (reason, label, counter_key) VALUES
    ('purchase', 'Compra', 'goods_received'),
    ('sale', 'Venda', 'cogs'),
    ('service_part', 'Peça de ordem de serviço', 'cogs'),
    ('project_material', 'Material de projeto', 'project_costs'),
    ('customer_return', 'Devolução de cliente', 'cogs'),
    ('adjustment_in', 'Ajuste de entrada', 'inventory_gains'),
    ('adjustment_out', 'Ajuste de saída', 'inventory_losses'),
    ('loss', 'Perda', 'inventory_losses'),
    ('scrap', 'Descarte', 'inventory_losses'),
    ('production_issue', 'Requisição de produção', 'work_in_process'),
    ('production_receipt', 'Entrega de produção', 'work_in_process'),
    ('transfer', 'Transferência', NULL),
    ('opening', 'Saldo de abertura', 'opening_balances');

-- Best known cost when there is no average yet: standard cost, preferred supplier price, zero.
CREATE FUNCTION inventory.fallback_cost(p_product integer) RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT standard_cost FROM production.item_plan WHERE product_id = p_product),
        (SELECT price FROM supply.supplier_item WHERE product_id = p_product ORDER BY preferred DESC, price LIMIT 1),
        0)::numeric
$$;

-- Values the given movements in order (item, id) under a lock on each item's cost row (RNF-038-02).
-- Set-based writes (RNF-038-01): one cost update per item and one update for all the movements.
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
            -- Goods in transit still belong to the company: informative cost, own stock unchanged.
            v_cost := COALESCE(v_avg, inventory.fallback_cost(m.product_id));
            v_value := round(m.quantity * v_cost, 2);
        ELSIF m.quantity > 0 THEN
            v_cost := COALESCE(m.unit_cost, v_avg, inventory.fallback_cost(m.product_id));
            v_value := round(m.quantity * v_cost, 2);
            v_qty := v_qty + m.quantity;
            v_val := v_val + v_value;
            v_avg := CASE WHEN v_qty > 0 THEN round(v_val / v_qty, 6) ELSE COALESCE(v_avg, v_cost) END;
        ELSE
            v_cost := COALESCE(v_avg, inventory.fallback_cost(m.product_id));
            -- The movement that empties the item takes what is left: no rounding residue.
            v_value := CASE WHEN v_qty + m.quantity = 0 THEN -v_val ELSE round(m.quantity * v_cost, 2) END;
            v_qty := v_qty + m.quantity;
            v_val := v_val + v_value;
            v_avg := COALESCE(v_avg, v_cost);
        END IF;
        ids := ids || m.id; costs := costs || round(v_cost, 6); vals := vals || v_value;
    END LOOP;
    IF v_pid IS NOT NULL THEN
        UPDATE inventory.item_cost SET quantity = v_qty, value = v_val, avg_cost = v_avg, updated_at = now() WHERE product_id = v_pid;
        UPDATE inventory.stock_movement s SET unit_cost = x.c, value = x.v
          FROM unnest(ids, costs, vals) AS x(id, c, v) WHERE s.id = x.id;
    END IF;
END $$;

-- One journal entry per document × reason in the transaction, from the posting rules (RF-038-01,
-- CA-038-02). Batches arrive as one statement per row: the entry of the document is kept in a
-- transaction-local setting and later movements add to its lines.
CREATE FUNCTION inventory.add_line(p_entry bigint, p_account text, p_debit numeric, p_credit numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF p_debit > 0 THEN
        UPDATE finance.journal_line SET debit = debit + p_debit WHERE entry_id = p_entry AND account = p_account AND debit > 0;
    ELSE
        UPDATE finance.journal_line SET credit = credit + p_credit WHERE entry_id = p_entry AND account = p_account AND credit > 0;
    END IF;
    IF NOT FOUND THEN
        INSERT INTO finance.journal_line (entry_id, account, debit, credit) VALUES (p_entry, p_account, p_debit, p_credit);
    END IF;
END $$;

CREATE FUNCTION inventory.post_movements(p_ids bigint[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    g record;
    v_entry bigint;
    v_key text;
    v_inventory text := finance.account_for('inventory');
    v_counter text;
    v_amount numeric;
BEGIN
    FOR g IN SELECT m.document, m.reason, r.label, r.counter_key, min(m.created_by) AS created_by, sum(m.value) AS total,
                    array_agg(m.id) AS ids
             FROM inventory.stock_movement m JOIN inventory.posting_rule r ON r.reason = m.reason
             WHERE m.id = ANY(p_ids) AND m.entry_id IS NULL AND r.counter_key IS NOT NULL
             GROUP BY m.document, m.reason, r.label, r.counter_key
             HAVING sum(m.value) <> 0
             ORDER BY m.document, m.reason LOOP
        v_counter := finance.account_for(g.counter_key);
        v_amount := abs(g.total);
        v_key := 'ana.mve_' || md5(COALESCE(g.document, '') || '|' || g.reason);
        v_entry := NULLIF(current_setting(v_key, true), '')::bigint;
        IF v_entry IS NULL OR NOT EXISTS (SELECT 1 FROM finance.journal_entry WHERE id = v_entry) THEN
            INSERT INTO finance.journal_entry (memo, document, created_by)
            VALUES (left('Estoque — ' || g.label || COALESCE(': ' || g.document, ''), 200), g.document, g.created_by)
            RETURNING id INTO v_entry;
            PERFORM set_config(v_key, v_entry::text, true);
        END IF;
        IF g.total > 0 THEN
            PERFORM inventory.add_line(v_entry, v_inventory, v_amount, 0);
            PERFORM inventory.add_line(v_entry, v_counter, 0, v_amount);
        ELSE
            PERFORM inventory.add_line(v_entry, v_counter, v_amount, 0);
            PERFORM inventory.add_line(v_entry, v_inventory, 0, v_amount);
        END IF;
        UPDATE inventory.stock_movement SET entry_id = v_entry WHERE id = ANY(g.ids);
    END LOOP;
END $$;

-- Movements of old programs (or of client programs) without a reason are adjustments (RNF-038-04).
CREATE FUNCTION inventory.movement_defaults() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.reason := COALESCE(NEW.reason, CASE WHEN NEW.quantity > 0 THEN 'adjustment_in' ELSE 'adjustment_out' END);
    IF NEW.quantity < 0 THEN
        NEW.unit_cost := NULL;     -- an outgoing movement always leaves at the average
    END IF;
    NEW.value := NULL;
    NEW.entry_id := NULL;
    RETURN NEW;
END $$;

-- Every statement that inserts movements values and posts them (one entry per document).
CREATE FUNCTION inventory.movements_inserted() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_ids bigint[];
BEGIN
    SELECT array_agg(id) INTO v_ids FROM new_rows;
    IF v_ids IS NOT NULL THEN
        PERFORM inventory.value_movements(v_ids);
        PERFORM inventory.post_movements(v_ids);
    END IF;
    RETURN NULL;
END $$;

-- A valued movement is history: product, warehouse, quantity, cost and value never change, nothing is deleted.
CREATE FUNCTION inventory.movement_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'MOVEMENT_IMMUTABLE: movimentação de estoque não se apaga; registre a movimentação contrária'
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.product_id <> OLD.product_id OR NEW.warehouse_id <> OLD.warehouse_id OR NEW.quantity <> OLD.quantity
       OR NEW.reason IS DISTINCT FROM OLD.reason
       OR (OLD.value IS NOT NULL AND NEW.value IS DISTINCT FROM OLD.value)
       OR (OLD.value IS NOT NULL AND NEW.unit_cost IS DISTINCT FROM OLD.unit_cost)
       OR (OLD.entry_id IS NOT NULL AND NEW.entry_id IS DISTINCT FROM OLD.entry_id) THEN
        RAISE EXCEPTION 'MOVEMENT_IMMUTABLE: movimentação de estoque não se altera; registre a movimentação contrária'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

-- ---------------------------------------------------------------- existing movements (RNF-038-03)
UPDATE inventory.stock_movement SET reason = CASE
        WHEN document LIKE 'OC-%' THEN 'purchase'
        WHEN document LIKE 'ORD-%' OR document LIKE 'EXP-%' THEN CASE WHEN quantity < 0 THEN 'sale' ELSE 'customer_return' END
        WHEN document LIKE 'OS-%' THEN 'service_part'
        WHEN document LIKE 'PRJ-%' THEN 'project_material'
        WHEN document LIKE 'OP-%' THEN CASE WHEN quantity < 0 THEN 'production_issue' ELSE 'production_receipt' END
        WHEN document LIKE 'TR-%' THEN 'transfer'
        WHEN document LIKE 'DEV-%' THEN 'customer_return'
        WHEN document LIKE 'OPENING%' THEN 'opening'
        WHEN quantity > 0 THEN 'adjustment_in'
        ELSE 'adjustment_out' END;
UPDATE inventory.stock_movement m SET unit_cost = rl.price
  FROM supply.receipt_line rl WHERE rl.stock_movement_id = m.id;
UPDATE inventory.stock_movement m SET unit_cost = round(o.std_cost / o.quantity, 6)
  FROM production.work_order o
 WHERE m.reason = 'production_receipt' AND m.document = 'OP-' || o.number AND o.std_cost IS NOT NULL AND o.quantity > 0;
UPDATE inventory.stock_movement SET unit_cost = NULL WHERE quantity < 0;
SELECT inventory.value_movements(ARRAY(SELECT id FROM inventory.stock_movement ORDER BY id));
-- No retroactive accounting: finance.inventory_opening_adjustment posts the difference once.

ALTER TABLE inventory.stock_movement ALTER COLUMN reason SET NOT NULL;
CREATE TRIGGER stock_movement_defaults BEFORE INSERT ON inventory.stock_movement
    FOR EACH ROW EXECUTE FUNCTION inventory.movement_defaults();
CREATE TRIGGER stock_movement_value AFTER INSERT ON inventory.stock_movement
    REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION inventory.movements_inserted();
CREATE TRIGGER stock_movement_immutable BEFORE UPDATE OR DELETE ON inventory.stock_movement
    FOR EACH ROW EXECUTE FUNCTION inventory.movement_immutable();

-- ---------------------------------------------------------------- control account of bills (RF-038-04)
ALTER TABLE finance.bill ADD COLUMN account text REFERENCES finance.account(code);
UPDATE finance.bill b SET account = COALESCE(
    (SELECT l.account FROM finance.journal_line l
      WHERE l.entry_id = b.entry_id
        AND l.account IN (SELECT account FROM finance.default_account WHERE key IN ('customers', 'suppliers', 'customer_credits'))
      ORDER BY l.id LIMIT 1),
    CASE WHEN b.kind = 'receivable' THEN finance.account_for('customers')
         WHEN b.document LIKE 'DEV-%' THEN finance.account_for('customer_credits')
         ELSE finance.account_for('suppliers') END);
CREATE FUNCTION finance.bill_defaults() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.account := COALESCE(NEW.account,
        finance.account_for(CASE WHEN NEW.kind = 'receivable' THEN 'customers' ELSE 'suppliers' END));
    RETURN NEW;
END $$;
CREATE TRIGGER bill_defaults BEFORE INSERT ON finance.bill FOR EACH ROW EXECUTE FUNCTION finance.bill_defaults();
ALTER TABLE finance.bill ALTER COLUMN account SET NOT NULL;
CREATE INDEX bill_account_open_idx ON finance.bill (account) WHERE status = 'open';

-- ---------------------------------------------------------------- freight (RF-038-03)
ALTER TABLE logistics.shipment ADD COLUMN freight_bill_id bigint REFERENCES finance.bill(id);
-- A carrier is paid like any supplier: each one gets its supplier party (same name, or a new one).
UPDATE logistics.carrier c SET party_id = (SELECT p.id FROM base.party p WHERE p.name = c.name AND p.kind IN ('supplier', 'both')
                                           ORDER BY p.id LIMIT 1)
 WHERE c.party_id IS NULL;
WITH missing AS (SELECT id, name FROM logistics.carrier WHERE party_id IS NULL),
     created AS (INSERT INTO base.party (kind, name) SELECT 'supplier', left(name, 200) FROM missing RETURNING id, name)
UPDATE logistics.carrier c SET party_id = created.id FROM created WHERE created.name = left(c.name, 200) AND c.party_id IS NULL;

-- Manual entries are the usual cause of a reconciliation difference: the detail lists them.
ALTER TABLE finance.journal_entry ADD COLUMN manual boolean NOT NULL DEFAULT false;
CREATE INDEX journal_entry_manual_idx ON finance.journal_entry (entry_date) WHERE manual;

-- Physical counts (RF-038-02): document INV-n.
CREATE SEQUENCE inventory.count_number_seq;

-- ---------------------------------------------------------------- period close (RF-038-09)
CREATE TABLE finance.period_close (
    id           bigserial PRIMARY KEY,
    closed_until date NOT NULL,
    action       text NOT NULL CHECK (action IN ('close', 'reopen')),
    reason       text,
    done_by      text NOT NULL,
    done_at      timestamptz NOT NULL DEFAULT now()
);
CREATE FUNCTION finance.closed_until() RETURNS date LANGUAGE sql STABLE AS $$
    SELECT closed_until FROM finance.period_close ORDER BY id DESC LIMIT 1
$$;
CREATE FUNCTION finance.entry_open_period() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v date := finance.closed_until();
BEGIN
    IF v IS NOT NULL AND (NEW.entry_date <= v OR (TG_OP = 'UPDATE' AND OLD.entry_date <= v)) THEN
        RAISE EXCEPTION 'PERIOD_CLOSED: período fechado até %; use uma data posterior ou peça ao administrador para reabrir',
            to_char(v, 'DD/MM/YYYY') USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER journal_entry_open_period BEFORE INSERT OR UPDATE ON finance.journal_entry
    FOR EACH ROW EXECUTE FUNCTION finance.entry_open_period();
CREATE FUNCTION finance.line_open_period() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v date := finance.closed_until();
BEGIN
    IF v IS NOT NULL AND EXISTS (SELECT 1 FROM finance.journal_entry
                                 WHERE id = COALESCE(NEW.entry_id, OLD.entry_id) AND entry_date <= v) THEN
        RAISE EXCEPTION 'PERIOD_CLOSED: período fechado até %', to_char(v, 'DD/MM/YYYY') USING ERRCODE = 'check_violation';
    END IF;
    RETURN COALESCE(NEW, OLD);
END $$;
CREATE TRIGGER journal_line_open_period BEFORE INSERT OR UPDATE OR DELETE ON finance.journal_line
    FOR EACH ROW EXECUTE FUNCTION finance.line_open_period();

-- ---------------------------------------------------------------- reconciliation (RF-038-04, CA-038-05)
-- Subledger × ledger for every control account, and documents that should have an entry but do not.
CREATE FUNCTION finance.reconciliation()
RETURNS TABLE (key text, label text, account text, subledger numeric, ledger numeric, difference numeric, items bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    WITH bal AS (
        SELECT l.account, sum(l.debit - l.credit) AS d FROM finance.journal_line l GROUP BY l.account
    ), ctl AS (
        SELECT b.account, sum(b.amount) AS open_amount, count(*) AS n
          FROM finance.bill b WHERE b.status = 'open' GROUP BY b.account
    ), keys AS (
        SELECT d.key, d.account FROM finance.default_account d
         WHERE d.key IN ('customers', 'suppliers', 'customer_credits')
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
    )
    SELECT k.key,
           CASE k.key WHEN 'customers' THEN 'Clientes (títulos a receber)'
                      WHEN 'suppliers' THEN 'Fornecedores (títulos a pagar)'
                      ELSE 'Créditos de clientes' END,
           k.account, COALESCE(c.open_amount, 0),
           COALESCE(CASE WHEN k.key = 'customers' THEN b.d ELSE -b.d END, 0),
           COALESCE(c.open_amount, 0) - COALESCE(CASE WHEN k.key = 'customers' THEN b.d ELSE -b.d END, 0),
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
      FROM (SELECT COALESCE(sum(m.value), 0) AS v, count(DISTINCT r.id) AS n
              FROM supply.receipt r JOIN supply.receipt_line rl ON rl.receipt_id = r.id
              JOIN inventory.stock_movement m ON m.id = rl.stock_movement_id
             WHERE r.bill_id IS NULL AND m.entry_id IS NOT NULL) x
    UNION ALL
    SELECT 'work_in_process', 'Produtos em elaboração (ordens abertas)', finance.account_for('work_in_process'),
           wip.issued + wip_hours.hours - wip_out.delivered,
           COALESCE((SELECT d FROM bal WHERE account = finance.account_for('work_in_process')), 0),
           wip.issued + wip_hours.hours - wip_out.delivered
             - COALESCE((SELECT d FROM bal WHERE account = finance.account_for('work_in_process')), 0),
           (SELECT count(*) FROM production.work_order WHERE status NOT IN ('closed', 'cancelled', 'planned'))
      FROM wip, wip_hours, wip_out
    UNION ALL
    SELECT 'bills_without_entry', 'Títulos sem lançamento', NULL, NULL, NULL,
           COALESCE(sum(amount), 0), count(*)
      FROM finance.bill WHERE entry_id IS NULL AND status <> 'cancelled'
    UNION ALL
    SELECT 'movements_without_entry', 'Movimentações de estoque valorizadas sem lançamento', NULL, NULL, NULL,
           COALESCE(sum(m.value), 0), count(*)
      FROM inventory.stock_movement m JOIN inventory.posting_rule r ON r.reason = m.reason
     WHERE r.counter_key IS NOT NULL AND m.entry_id IS NULL AND m.value <> 0
       AND m.created_at > (SELECT COALESCE(max(applied_at), now()) FROM ana_system.migration
                            WHERE name = '037_inventory_valuation')
    UNION ALL
    SELECT 'freight_without_bill', 'Fretes de expedição sem título da transportadora', NULL, NULL, NULL,
           COALESCE(sum(s.freight_cost), 0), count(*)
      FROM logistics.shipment s
     WHERE s.freight_cost > 0 AND s.freight_bill_id IS NULL AND s.status NOT IN ('cancelled')
       AND s.created_at > (SELECT COALESCE(max(applied_at), now()) FROM ana_system.migration
                            WHERE name = '037_inventory_valuation')
$$;

-- ---------------------------------------------------------------- grants
GRANT SELECT ON inventory.item_cost, inventory.posting_rule TO ana_exec, ana_read;
GRANT SELECT, INSERT ON finance.period_close TO ana_exec;
GRANT SELECT ON finance.period_close TO ana_read;
GRANT USAGE ON SEQUENCE finance.period_close_id_seq, inventory.count_number_seq TO ana_exec;
REVOKE ALL ON FUNCTION inventory.value_movements(bigint[]), inventory.post_movements(bigint[]),
                       inventory.add_line(bigint, text, numeric, numeric),
                       inventory.movements_inserted() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION finance.reconciliation(), finance.closed_until(), inventory.fallback_cost(integer) TO ana_exec, ana_read;
