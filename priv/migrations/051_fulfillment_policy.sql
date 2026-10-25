-- Spec 041: the sales order is fulfilled by the company's policy (refuse, hold, buy, make, by the item, accept),
-- with exceptions per item, item group, customer and customer + item; reservation per order line; the supply it
-- starts (purchase request, work order, purchases of components) stays linked to the order.

-- Item group: exceptions by group of items (RF-041-01).
ALTER TABLE base.product ADD COLUMN item_group text CHECK (item_group IS NULL OR item_group ~ '^[A-Z0-9_-]{1,30}$');
CREATE INDEX product_item_group_idx ON base.product (item_group) WHERE item_group IS NOT NULL;

-- RF-041-01: one row (the installation's policy). Out of the box it keeps the earlier behavior: accept and warn.
CREATE TABLE sales.fulfillment_policy (
    id              integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    mode            text NOT NULL DEFAULT 'accept' CHECK (mode IN ('refuse', 'hold', 'purchase', 'produce', 'by_item', 'accept')),
    transfer_first  boolean NOT NULL DEFAULT false,          -- D3: other warehouses' stock before supplying
    auto_order_max  numeric(14,2) NOT NULL DEFAULT 0 CHECK (auto_order_max >= 0),   -- purchase becomes an order by itself up to this
    allowed_modes   text[] NOT NULL DEFAULT '{}',            -- modes whoever types the order may choose instead
    confirm_cancel  boolean NOT NULL DEFAULT true,           -- D6: show the effect and ask before cancelling
    updated_by      text,
    updated_at      timestamptz
);
INSERT INTO sales.fulfillment_policy (id) VALUES (1) ON CONFLICT DO NOTHING;

-- Exceptions: the most specific wins (customer + item > item > item group > customer > policy).
CREATE TABLE sales.fulfillment_rule (
    id             serial PRIMARY KEY,
    customer_id    integer REFERENCES base.party(id) ON DELETE CASCADE,
    product_id     integer REFERENCES base.product(id) ON DELETE CASCADE,
    item_group     text CHECK (item_group IS NULL OR item_group ~ '^[A-Z0-9_-]{1,30}$'),
    mode           text NOT NULL CHECK (mode IN ('refuse', 'hold', 'purchase', 'produce', 'by_item', 'accept')),
    transfer_first boolean,                                   -- null = the policy's
    note           text NOT NULL DEFAULT '',
    created_by     text NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CHECK (customer_id IS NOT NULL OR product_id IS NOT NULL OR item_group IS NOT NULL),
    CHECK (NOT (product_id IS NOT NULL AND item_group IS NOT NULL))
);
CREATE UNIQUE INDEX fulfillment_rule_uk ON sales.fulfillment_rule (COALESCE(customer_id, 0), COALESCE(product_id, 0), COALESCE(item_group, ''));
CREATE INDEX fulfillment_rule_product_idx ON sales.fulfillment_rule (product_id);

-- RF-041-02/03, D5: what each line does and promises. reserve_qty = what the line holds of the warehouse's stock
-- (null on older orders = the whole quantity, as before).
ALTER TABLE sales.sales_order_item
    ADD COLUMN fulfill_mode  text CHECK (fulfill_mode IN ('refuse', 'hold', 'purchase', 'produce', 'by_item', 'accept')),
    ADD COLUMN rule_source   text,
    ADD COLUMN from_stock    numeric(14,3),
    ADD COLUMN transfer_qty  numeric(14,3) NOT NULL DEFAULT 0,
    ADD COLUMN supply_qty    numeric(14,3) NOT NULL DEFAULT 0,
    ADD COLUMN supply_kind   text CHECK (supply_kind IN ('purchase', 'production')),
    ADD COLUMN promised_date date,
    ADD COLUMN reserve_qty   numeric(14,3) CHECK (reserve_qty >= 0);

-- ok: can ship; held: waits for stock (hold); supply: waits for the linked purchase/production; short: accepted
-- without stock, someone decides ("Pedidos com falta").
ALTER TABLE sales.sales_order ADD COLUMN fulfillment text NOT NULL DEFAULT 'ok'
    CHECK (fulfillment IN ('ok', 'held', 'supply', 'short'));
CREATE INDEX sales_order_fulfillment_idx ON sales.sales_order (fulfillment) WHERE fulfillment <> 'ok';

-- D4 / RF-041-07: supply linked to the order (and components to the work order).
ALTER TABLE supply.purchase_request DROP CONSTRAINT purchase_request_origin_check;
ALTER TABLE supply.purchase_request ADD CONSTRAINT purchase_request_origin_check
    CHECK (origin IN ('manual', 'replenishment', 'planning', 'project', 'sales'));
ALTER TABLE supply.purchase_request_line
    ADD COLUMN sales_order_id integer REFERENCES sales.sales_order(id),
    ADD COLUMN sales_order_line smallint,
    ADD COLUMN work_order_id integer REFERENCES production.work_order(id);
CREATE INDEX purchase_request_line_sales_idx ON supply.purchase_request_line (sales_order_id) WHERE sales_order_id IS NOT NULL;
CREATE INDEX purchase_request_line_wo_idx ON supply.purchase_request_line (work_order_id) WHERE work_order_id IS NOT NULL;
ALTER TABLE production.work_order
    ADD COLUMN sales_order_id integer REFERENCES sales.sales_order(id),
    ADD COLUMN sales_order_line smallint;
CREATE INDEX work_order_sales_idx ON production.work_order (sales_order_id) WHERE sales_order_id IS NOT NULL;

-- RF-041-03: available = stock − reserved everywhere; a line reserves reserve_qty (what it took or what its
-- supply brings), minus what already left the stock.
CREATE OR REPLACE VIEW inventory.reserved AS
SELECT product_id, warehouse_id, sum(quantity) AS quantity FROM (
    SELECT i.product_id, o.warehouse_id,
           greatest(COALESCE(i.reserve_qty, i.quantity) - CASE WHEN (SELECT stock_out_on FROM logistics.policy WHERE id = 1) = 'shipment'
               THEN COALESCE((SELECT sum(l.quantity) FROM logistics.shipment_line l JOIN logistics.shipment s ON s.id = l.shipment_id
                              WHERE s.sales_order_id = o.id AND l.order_line = i.line AND s.stock_moved), 0) ELSE 0 END, 0) AS quantity
    FROM sales.sales_order_item i JOIN sales.sales_order o ON o.id = i.order_id WHERE o.status = 'OPEN'
    UNION ALL
    SELECT c.product_id, w.warehouse_id, greatest(c.reserved_qty - c.issued_qty, 0)
    FROM production.order_component c JOIN production.work_order w ON w.id = c.order_id
    WHERE w.status IN ('released', 'in_progress')
) r GROUP BY product_id, warehouse_id;

-- A held or supplied order moves on when its stock is there (RF-041-06): every goods line fits in the warehouse's
-- stock after the open orders before it (earlier number, or already free to ship) and the work orders' components.
CREATE FUNCTION sales.order_ready(p_order integer) RETURNS boolean
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
    WITH o AS (SELECT id, number, warehouse_id FROM sales.sales_order WHERE id = p_order),
    need AS (SELECT i.product_id, sum(i.quantity) AS q FROM sales.sales_order_item i JOIN base.product p ON p.id = i.product_id
             WHERE i.order_id = p_order AND p.kind = 'goods' GROUP BY 1),
    stock AS (SELECT m.product_id, sum(m.quantity) AS q FROM inventory.stock_movement m, o
              WHERE m.warehouse_id = o.warehouse_id AND m.product_id IN (SELECT product_id FROM need) GROUP BY 1),
    before AS (SELECT i.product_id, sum(COALESCE(i.reserve_qty, i.quantity)) AS q
               FROM sales.sales_order_item i JOIN sales.sales_order x ON x.id = i.order_id, o
               WHERE x.status = 'OPEN' AND x.id <> o.id AND x.warehouse_id = o.warehouse_id
                 AND (x.fulfillment = 'ok' OR x.number < o.number) AND i.product_id IN (SELECT product_id FROM need) GROUP BY 1),
    comp AS (SELECT c.product_id, sum(greatest(c.reserved_qty - c.issued_qty, 0)) AS q
             FROM production.order_component c JOIN production.work_order w ON w.id = c.order_id, o
             WHERE w.status IN ('released', 'in_progress') AND w.warehouse_id = o.warehouse_id
               AND c.product_id IN (SELECT product_id FROM need) GROUP BY 1)
    SELECT COALESCE(bool_and(COALESCE(s.q, 0) - COALESCE(b.q, 0) - COALESCE(c.q, 0) >= n.q), true)
    FROM need n LEFT JOIN stock s ON s.product_id = n.product_id LEFT JOIN before b ON b.product_id = n.product_id
    LEFT JOIN comp c ON c.product_id = n.product_id
$$;

-- RF-041-06: the document's situation changed (stock arrived): its waiting steps are evaluated again.
CREATE FUNCTION flow.resume_document(p_flow text, p_key text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_n integer;
BEGIN
    UPDATE flow.instance_step x SET status = 'ready', next_at = now(), attempts = 0, force = false, error = NULL, lease_until = NULL
    FROM flow.instance i WHERE i.id = x.instance_id AND i.flow_code = p_flow AND i.doc_key = p_key AND x.status = 'waiting';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN
        UPDATE flow.instance SET status = 'running', updated_at = now() WHERE flow_code = p_flow AND doc_key = p_key AND status = 'waiting';
        PERFORM pg_notify('ana_flow', (SELECT id::text FROM flow.instance WHERE flow_code = p_flow AND doc_key = p_key));
    END IF;
    RETURN v_n;
END $$;
REVOKE EXECUTE ON FUNCTION flow.resume_document(text, text) FROM PUBLIC;

GRANT SELECT, INSERT, UPDATE ON sales.fulfillment_policy TO ana_exec;
GRANT SELECT, INSERT, UPDATE, DELETE ON sales.fulfillment_rule TO ana_exec;
GRANT USAGE, SELECT ON SEQUENCE sales.fulfillment_rule_id_seq TO ana_exec;
GRANT SELECT ON sales.fulfillment_policy, sales.fulfillment_rule TO ana_read;
GRANT SELECT ON inventory.reserved TO ana_exec, ana_read;
GRANT EXECUTE ON FUNCTION sales.order_ready(integer), flow.resume_document(text, text) TO ana_exec;
SELECT ana_system.sync_scoped_role();
