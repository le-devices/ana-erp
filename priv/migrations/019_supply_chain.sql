-- 019 — Supply chain: purchasing, suppliers, receiving, replenishment (spec 013)

CREATE SCHEMA IF NOT EXISTS supply;

-- Accounts used by purchasing (P13: adjustable in finance.default_account).
INSERT INTO finance.account (code, description, nature, postable, cost_center_policy) VALUES
    ('5.1.2', 'Serviços contratados', 'expense', true, 'required'),
    ('5.1.3', 'Custos diretos de projetos (compras)', 'expense', true, 'required')
ON CONFLICT DO NOTHING;
INSERT INTO finance.default_account (key, account, description) VALUES
    ('inventory', '1.1.3', 'Estoques (entrada de compras)'),
    ('suppliers', '2.1.1', 'Fornecedores (títulos a pagar)'),
    ('purchased_services', '5.1.2', 'Serviços contratados'),
    ('project_costs', '5.1.3', 'Compras (mercadorias e serviços) para projetos')
ON CONFLICT DO NOTHING;

CREATE TABLE supply.policy (
    id                  integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    receipt_tolerance_pct numeric(5,2) NOT NULL DEFAULT 0 CHECK (receipt_tolerance_pct BETWEEN 0 AND 100),
    default_payment_days integer NOT NULL DEFAULT 30 CHECK (default_payment_days BETWEEN 0 AND 365)
);
INSERT INTO supply.policy (id) VALUES (1) ON CONFLICT DO NOTHING;

-- RF-013-01
CREATE TABLE supply.supplier_item (
    id             serial PRIMARY KEY,
    supplier_id    integer NOT NULL REFERENCES base.party(id),
    product_id     integer NOT NULL REFERENCES base.product(id),
    supplier_code  text,
    price          numeric(14,4) NOT NULL CHECK (price >= 0),
    currency       text NOT NULL DEFAULT 'BRL' CHECK (currency ~ '^[A-Z]{3}$'),
    lead_time_days integer NOT NULL DEFAULT 0 CHECK (lead_time_days BETWEEN 0 AND 730),
    min_qty        numeric(14,3) NOT NULL DEFAULT 0 CHECK (min_qty >= 0),
    multiple       numeric(14,3) NOT NULL DEFAULT 0 CHECK (multiple >= 0),
    preferred      boolean NOT NULL DEFAULT false,
    valid_until    date,
    UNIQUE (supplier_id, product_id)
);
CREATE UNIQUE INDEX supplier_item_preferred_uk ON supply.supplier_item (product_id) WHERE preferred;
CREATE INDEX supplier_item_product_idx ON supply.supplier_item (product_id);

-- RF-013-03: approval limits (NULL = unlimited). The product ships only admin.
CREATE TABLE supply.approval_limit (
    target_kind text NOT NULL CHECK (target_kind IN ('role', 'group')),
    target      text NOT NULL,
    max_amount  numeric(14,2) CHECK (max_amount >= 0),
    PRIMARY KEY (target_kind, target)
);
INSERT INTO supply.approval_limit (target_kind, target, max_amount) VALUES ('role', 'admin', NULL) ON CONFLICT DO NOTHING;

-- Largest limit of a user (by role or by access group): NULL = unlimited, 0 = may not approve.
-- SECURITY DEFINER: programs (ana_exec) do not read ana_system.user_group.
CREATE FUNCTION supply.approval_limit_of(p_user text, p_role text) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT CASE WHEN count(*) = 0 THEN 0
                WHEN bool_or(l.max_amount IS NULL) THEN NULL
                ELSE max(l.max_amount) END
    FROM supply.approval_limit l
    WHERE (l.target_kind = 'role' AND l.target = p_role)
       OR (l.target_kind = 'group' AND EXISTS (SELECT 1 FROM ana_system.user_group g
                                               WHERE g.username = p_user AND g.group_name = l.target))
$$;

CREATE SEQUENCE supply.request_number START 1;
CREATE SEQUENCE supply.order_number START 1;

-- RF-013-02
CREATE TABLE supply.purchase_request (
    id               serial PRIMARY KEY,
    number           bigint NOT NULL UNIQUE DEFAULT nextval('supply.request_number'),
    requester        text NOT NULL,
    need_date        date,
    reason           text NOT NULL DEFAULT '',
    project_id       integer REFERENCES projects.project(id),
    warehouse_id     integer NOT NULL REFERENCES inventory.warehouse(id),
    cost_center      text REFERENCES finance.cost_center(code) ON UPDATE CASCADE,
    origin           text NOT NULL DEFAULT 'manual' CHECK (origin IN ('manual', 'replenishment', 'planning', 'project')),
    status           text NOT NULL DEFAULT 'draft'
                     CHECK (status IN ('draft', 'submitted', 'approved', 'rejected', 'ordered', 'cancelled')),
    total            numeric(14,2) NOT NULL DEFAULT 0,
    approved_by      text,
    approved_at      timestamptz,
    rejection_reason text,
    created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX purchase_request_status_idx ON supply.purchase_request (status);
CREATE INDEX purchase_request_project_idx ON supply.purchase_request (project_id);
CREATE INDEX purchase_request_warehouse_idx ON supply.purchase_request (warehouse_id);
CREATE INDEX purchase_request_cc_idx ON supply.purchase_request (cost_center);

CREATE TABLE supply.purchase_request_line (
    request_id  integer NOT NULL REFERENCES supply.purchase_request(id) ON DELETE CASCADE,
    line        smallint NOT NULL CHECK (line > 0),
    product_id  integer NOT NULL REFERENCES base.product(id),
    quantity    numeric(14,3) NOT NULL CHECK (quantity > 0),
    est_price   numeric(14,4) NOT NULL DEFAULT 0 CHECK (est_price >= 0),
    supplier_id integer REFERENCES base.party(id),
    rebillable  boolean NOT NULL DEFAULT false,
    PRIMARY KEY (request_id, line)
);
CREATE INDEX purchase_request_line_product_idx ON supply.purchase_request_line (product_id);
CREATE INDEX purchase_request_line_supplier_idx ON supply.purchase_request_line (supplier_id);

-- RF-013-04
CREATE TABLE supply.purchase_order (
    id           serial PRIMARY KEY,
    number       bigint NOT NULL UNIQUE DEFAULT nextval('supply.order_number'),
    supplier_id  integer NOT NULL REFERENCES base.party(id),
    warehouse_id integer NOT NULL REFERENCES inventory.warehouse(id),
    status       text NOT NULL DEFAULT 'draft'
                 CHECK (status IN ('draft', 'sent', 'partially_received', 'received', 'cancelled')),
    payment_days integer NOT NULL DEFAULT 30 CHECK (payment_days BETWEEN 0 AND 365),
    total        numeric(14,2) NOT NULL DEFAULT 0,
    notes        text,
    created_by   text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    sent_at      timestamptz
);
CREATE INDEX purchase_order_supplier_idx ON supply.purchase_order (supplier_id);
CREATE INDEX purchase_order_status_idx ON supply.purchase_order (status);
CREATE INDEX purchase_order_warehouse_idx ON supply.purchase_order (warehouse_id);

CREATE TABLE supply.purchase_order_line (
    order_id       integer NOT NULL REFERENCES supply.purchase_order(id) ON DELETE CASCADE,
    line           smallint NOT NULL CHECK (line > 0),
    product_id     integer NOT NULL REFERENCES base.product(id),
    quantity       numeric(14,3) NOT NULL CHECK (quantity > 0),
    price          numeric(14,4) NOT NULL CHECK (price >= 0),
    promised_date  date,
    received_qty   numeric(14,3) NOT NULL DEFAULT 0 CHECK (received_qty >= 0),
    request_id     integer REFERENCES supply.purchase_request(id),
    request_line   smallint,
    project_id     integer REFERENCES projects.project(id),
    cost_center    text REFERENCES finance.cost_center(code) ON UPDATE CASCADE,
    rebillable     boolean NOT NULL DEFAULT false,
    PRIMARY KEY (order_id, line)
);
CREATE INDEX purchase_order_line_product_idx ON supply.purchase_order_line (product_id);
CREATE INDEX purchase_order_line_request_idx ON supply.purchase_order_line (request_id);
CREATE INDEX purchase_order_line_project_idx ON supply.purchase_order_line (project_id);
CREATE INDEX purchase_order_line_cc_idx ON supply.purchase_order_line (cost_center);
ALTER TABLE supply.purchase_order_line SET (fillfactor = 90);

-- RF-013-05/06
CREATE TABLE supply.receipt (
    id          serial PRIMARY KEY,
    order_id    integer NOT NULL REFERENCES supply.purchase_order(id),
    document    text,
    received_by text NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    total       numeric(14,2) NOT NULL DEFAULT 0,
    entry_id    bigint REFERENCES finance.journal_entry(id),
    bill_id     bigint REFERENCES finance.bill(id)
);
CREATE INDEX receipt_order_idx ON supply.receipt (order_id);
CREATE INDEX receipt_entry_idx ON supply.receipt (entry_id);
CREATE INDEX receipt_bill_idx ON supply.receipt (bill_id);

CREATE TABLE supply.receipt_line (
    receipt_id         integer NOT NULL REFERENCES supply.receipt(id) ON DELETE CASCADE,
    order_line         smallint NOT NULL,
    quantity           numeric(14,3) NOT NULL CHECK (quantity > 0),
    price              numeric(14,4) NOT NULL,
    note               text,
    stock_movement_id  bigint REFERENCES inventory.stock_movement(id),
    project_expense_id bigint REFERENCES projects.expense(id),
    PRIMARY KEY (receipt_id, order_line)
);
CREATE INDEX receipt_line_movement_idx ON supply.receipt_line (stock_movement_id);
CREATE INDEX receipt_line_expense_idx ON supply.receipt_line (project_expense_id);

-- RNF-013-01: never receive above quantity × (1 + tolerance); closed orders are immutable.
CREATE FUNCTION supply.order_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_status text;
    v_tol numeric;
BEGIN
    SELECT status INTO v_status FROM supply.purchase_order WHERE id = COALESCE(NEW.order_id, OLD.order_id);
    IF v_status IN ('received', 'cancelled') THEN
        RAISE EXCEPTION 'ORDER_CLOSED: ordem % está %', COALESCE(NEW.order_id, OLD.order_id), v_status
            USING ERRCODE = 'check_violation';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    SELECT receipt_tolerance_pct INTO v_tol FROM supply.policy WHERE id = 1;
    IF NEW.received_qty > NEW.quantity * (1 + COALESCE(v_tol, 0) / 100) THEN
        RAISE EXCEPTION 'OVER_RECEIPT: recebido % acima do pedido % (tolerância %%%)', NEW.received_qty, NEW.quantity, COALESCE(v_tol, 0)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER purchase_order_line_guard BEFORE INSERT OR UPDATE OR DELETE ON supply.purchase_order_line
    FOR EACH ROW EXECUTE FUNCTION supply.order_line_guard();

-- Valid state transitions (orders and requests).
CREATE FUNCTION supply.status_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    ok boolean;
BEGIN
    IF NEW.status = OLD.status THEN RETURN NEW; END IF;
    IF TG_TABLE_NAME = 'purchase_order' THEN
        ok := (OLD.status, NEW.status) IN (('draft', 'sent'), ('draft', 'cancelled'), ('sent', 'partially_received'),
               ('sent', 'received'), ('sent', 'cancelled'), ('partially_received', 'received'),
               ('partially_received', 'cancelled'));
    ELSE
        ok := (OLD.status, NEW.status) IN (('draft', 'submitted'), ('draft', 'cancelled'), ('submitted', 'approved'),
               ('submitted', 'rejected'), ('submitted', 'cancelled'), ('approved', 'ordered'), ('approved', 'cancelled'));
    END IF;
    IF NOT ok THEN
        RAISE EXCEPTION 'INVALID_STATE: % não pode passar de % para %', TG_TABLE_NAME, OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER purchase_order_status BEFORE UPDATE OF status ON supply.purchase_order
    FOR EACH ROW EXECUTE FUNCTION supply.status_guard();
CREATE TRIGGER purchase_request_status BEFORE UPDATE OF status ON supply.purchase_request
    FOR EACH ROW EXECUTE FUNCTION supply.status_guard();

-- RF-013-07
CREATE TABLE supply.replenishment_rule (
    product_id   integer NOT NULL REFERENCES base.product(id),
    warehouse_id integer NOT NULL REFERENCES inventory.warehouse(id),
    min_qty      numeric(14,3) NOT NULL CHECK (min_qty >= 0),
    safety_qty   numeric(14,3) NOT NULL DEFAULT 0 CHECK (safety_qty >= 0),
    max_qty      numeric(14,3) NOT NULL CHECK (max_qty >= 0),
    method       text NOT NULL DEFAULT 'min_max' CHECK (method IN ('min_max', 'average_consumption')),
    window_days  integer NOT NULL DEFAULT 90 CHECK (window_days BETWEEN 7 AND 730),
    PRIMARY KEY (product_id, warehouse_id),
    CHECK (max_qty >= min_qty)
);
CREATE INDEX replenishment_rule_warehouse_idx ON supply.replenishment_rule (warehouse_id);

-- RNF-013-03: set-based figures, shared with specs 014 and 015.
CREATE VIEW supply.on_order AS
SELECT l.product_id, o.warehouse_id, sum(l.quantity - LEAST(l.received_qty, l.quantity)) AS quantity
FROM supply.purchase_order_line l JOIN supply.purchase_order o ON o.id = l.order_id
WHERE o.status IN ('draft', 'sent', 'partially_received') AND l.project_id IS NULL
GROUP BY l.product_id, o.warehouse_id;

CREATE VIEW inventory.reserved AS
SELECT i.product_id, o.warehouse_id, sum(i.quantity) AS quantity
FROM sales.sales_order_item i JOIN sales.sales_order o ON o.id = i.order_id
WHERE o.status = 'OPEN'
GROUP BY i.product_id, o.warehouse_id;

DO $$
BEGIN
    REVOKE ALL ON SCHEMA supply FROM PUBLIC;
    GRANT USAGE ON SCHEMA supply TO ana_exec, ana_read;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA supply TO ana_exec;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA supply TO ana_exec;
    GRANT SELECT ON ALL TABLES IN SCHEMA supply TO ana_read;
    GRANT SELECT ON inventory.reserved TO ana_exec, ana_read;
    ALTER DEFAULT PRIVILEGES IN SCHEMA supply GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ana_exec;
    ALTER DEFAULT PRIVILEGES IN SCHEMA supply GRANT USAGE, SELECT ON SEQUENCES TO ana_exec;
    REVOKE EXECUTE ON FUNCTION supply.order_line_guard(), supply.status_guard(), supply.approval_limit_of(text, text) FROM PUBLIC;
    GRANT EXECUTE ON FUNCTION supply.approval_limit_of(text, text) TO ana_exec;
END $$;
