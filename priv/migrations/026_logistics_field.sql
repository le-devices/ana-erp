-- 026 — Logistics and field service (spec 015)

CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA IF NOT EXISTS logistics;
CREATE SCHEMA IF NOT EXISTS field;

INSERT INTO finance.account (code, description, nature, postable, cost_center_policy) VALUES
    ('4.1.9', 'Devoluções de vendas', 'revenue', true, 'required'),
    ('2.1.2', 'Créditos de clientes', 'liability', true, 'none')
ON CONFLICT DO NOTHING;
INSERT INTO finance.default_account (key, account, description) VALUES
    ('sales_returns', '4.1.9', 'Devoluções de vendas (redução da receita)'),
    ('customer_credits', '2.1.2', 'Créditos a devolver a clientes')
ON CONFLICT DO NOTHING;
INSERT INTO inventory.warehouse (code, description) VALUES
    ('TRANSITO', 'Em trânsito entre depósitos'), ('QUARENTENA', 'Devoluções em inspeção')
ON CONFLICT DO NOTHING;

CREATE TABLE logistics.policy (
    id                 integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    stock_out_on       text NOT NULL DEFAULT 'invoice' CHECK (stock_out_on IN ('invoice', 'shipment')),
    travel_hour_rate   numeric(12,2) NOT NULL DEFAULT 0 CHECK (travel_hour_rate >= 0),
    travel_km_rate     numeric(12,2) NOT NULL DEFAULT 0 CHECK (travel_km_rate >= 0)
);
INSERT INTO logistics.policy (id) VALUES (1) ON CONFLICT DO NOTHING;

-- RF-015-03
CREATE TABLE logistics.carrier (
    id              serial PRIMARY KEY,
    name            text NOT NULL UNIQUE,
    party_id        integer REFERENCES base.party(id),
    tracking_url    text CHECK (tracking_url ~ '^https://'),
    active          boolean NOT NULL DEFAULT true
);
CREATE INDEX carrier_party_idx ON logistics.carrier (party_id);
CREATE TABLE logistics.freight_rate (
    carrier_id    integer NOT NULL REFERENCES logistics.carrier(id) ON DELETE CASCADE,
    region        text NOT NULL DEFAULT '*' CHECK (region ~ '^([A-Z]{2}|\*)$'),
    max_weight_kg numeric(10,3) NOT NULL CHECK (max_weight_kg > 0),
    price         numeric(12,2) NOT NULL CHECK (price >= 0),
    PRIMARY KEY (carrier_id, region, max_weight_kg)
);

-- RF-015-01
CREATE SEQUENCE logistics.transfer_number START 1;
CREATE TABLE logistics.transfer (
    id           serial PRIMARY KEY,
    number       bigint NOT NULL UNIQUE DEFAULT nextval('logistics.transfer_number'),
    from_wh      integer NOT NULL REFERENCES inventory.warehouse(id),
    to_wh        integer NOT NULL REFERENCES inventory.warehouse(id),
    status       text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'shipped', 'received', 'cancelled')),
    notes        text NOT NULL DEFAULT '',
    created_by   text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    shipped_at   timestamptz,
    received_at  timestamptz,
    CHECK (from_wh <> to_wh)
);
CREATE INDEX transfer_from_idx ON logistics.transfer (from_wh);
CREATE INDEX transfer_to_idx ON logistics.transfer (to_wh);
CREATE INDEX transfer_status_idx ON logistics.transfer (status) WHERE status IN ('draft', 'shipped');
CREATE TABLE logistics.transfer_line (
    transfer_id  integer NOT NULL REFERENCES logistics.transfer(id) ON DELETE CASCADE,
    line         smallint NOT NULL CHECK (line > 0),
    product_id   integer NOT NULL REFERENCES base.product(id),
    quantity     numeric(14,3) NOT NULL CHECK (quantity > 0),
    received_qty numeric(14,3) CHECK (received_qty >= 0),
    divergence   text,
    PRIMARY KEY (transfer_id, line)
);
CREATE INDEX transfer_line_product_idx ON logistics.transfer_line (product_id);

-- RF-015-02
CREATE SEQUENCE logistics.shipment_number START 1;
CREATE TABLE logistics.shipment (
    id               serial PRIMARY KEY,
    number           bigint NOT NULL UNIQUE DEFAULT nextval('logistics.shipment_number'),
    sales_order_id   integer NOT NULL REFERENCES sales.sales_order(id),
    status           text NOT NULL DEFAULT 'picking'
                     CHECK (status IN ('picking', 'packed', 'shipped', 'delivered', 'returned', 'cancelled')),
    carrier_id       integer REFERENCES logistics.carrier(id),
    tracking         text,
    packages         integer CHECK (packages > 0),
    weight_kg        numeric(10,3) CHECK (weight_kg > 0),
    freight_cost     numeric(12,2) CHECK (freight_cost >= 0),
    freight_charged  numeric(12,2) CHECK (freight_charged >= 0),
    expected_date    date,
    shipped_at       timestamptz,
    delivered_at     timestamptz,
    received_by      text,
    stock_moved      boolean NOT NULL DEFAULT false,
    created_by       text NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (carrier_id, tracking)
);
CREATE INDEX shipment_order_idx ON logistics.shipment (sales_order_id);
CREATE INDEX shipment_status_idx ON logistics.shipment (status) WHERE status IN ('picking', 'packed', 'shipped');
CREATE TABLE logistics.shipment_line (
    shipment_id  integer NOT NULL REFERENCES logistics.shipment(id) ON DELETE CASCADE,
    order_line   smallint NOT NULL,
    product_id   integer NOT NULL REFERENCES base.product(id),
    quantity     numeric(14,3) NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (shipment_id, order_line)
);
CREATE INDEX shipment_line_product_idx ON logistics.shipment_line (product_id);

-- Never ship more than ordered (shipments not cancelled/returned).
CREATE FUNCTION logistics.shipment_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_order integer;
    v_ordered numeric;
    v_shipped numeric;
BEGIN
    SELECT sales_order_id INTO v_order FROM logistics.shipment WHERE id = NEW.shipment_id;
    SELECT quantity INTO v_ordered FROM sales.sales_order_item WHERE order_id = v_order AND line = NEW.order_line;
    IF v_ordered IS NULL THEN
        RAISE EXCEPTION 'LINE_NOT_FOUND: o pedido não tem a linha %', NEW.order_line USING ERRCODE = 'check_violation';
    END IF;
    SELECT COALESCE(sum(l.quantity), 0) INTO v_shipped FROM logistics.shipment_line l JOIN logistics.shipment s ON s.id = l.shipment_id
    WHERE s.sales_order_id = v_order AND l.order_line = NEW.order_line AND s.status NOT IN ('cancelled', 'returned');
    IF v_shipped > v_ordered THEN
        RAISE EXCEPTION 'OVER_SHIPMENT: linha % do pedido: expedido % acima do pedido %', NEW.order_line, v_shipped, v_ordered
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER shipment_line_guard AFTER INSERT OR UPDATE ON logistics.shipment_line
    FOR EACH ROW EXECUTE FUNCTION logistics.shipment_line_guard();

CREATE VIEW logistics.order_shipping AS
SELECT o.id AS sales_order_id, o.number, sum(i.quantity) AS ordered,
       COALESCE(sum(sh.q), 0) AS shipped,
       CASE WHEN COALESCE(sum(sh.q), 0) = 0 THEN 'none'
            WHEN COALESCE(sum(sh.q), 0) >= sum(i.quantity) THEN 'full' ELSE 'partial' END AS state
FROM sales.sales_order o JOIN sales.sales_order_item i ON i.order_id = o.id
LEFT JOIN (SELECT s.sales_order_id, l.order_line, sum(l.quantity) AS q FROM logistics.shipment_line l
           JOIN logistics.shipment s ON s.id = l.shipment_id WHERE s.status NOT IN ('cancelled', 'returned')
           GROUP BY 1, 2) sh ON sh.sales_order_id = o.id AND sh.order_line = i.line
GROUP BY o.id, o.number;

-- RF-015-04
CREATE SEQUENCE logistics.return_number START 1;
CREATE TABLE logistics.customer_return (
    id             serial PRIMARY KEY,
    number         bigint NOT NULL UNIQUE DEFAULT nextval('logistics.return_number'),
    customer_id    integer NOT NULL REFERENCES base.party(id),
    sales_order_id integer REFERENCES sales.sales_order(id),
    warehouse_id   integer NOT NULL REFERENCES inventory.warehouse(id),
    reason         text NOT NULL CHECK (length(reason) >= 3),
    total          numeric(14,2) NOT NULL DEFAULT 0,
    entry_id       bigint REFERENCES finance.journal_entry(id),
    bill_id        bigint REFERENCES finance.bill(id),
    created_by     text NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX customer_return_customer_idx ON logistics.customer_return (customer_id);
CREATE INDEX customer_return_order_idx ON logistics.customer_return (sales_order_id);
CREATE INDEX customer_return_warehouse_idx ON logistics.customer_return (warehouse_id);
CREATE INDEX customer_return_entry_idx ON logistics.customer_return (entry_id);
CREATE INDEX customer_return_bill_idx ON logistics.customer_return (bill_id);
CREATE TABLE logistics.return_line (
    return_id   integer NOT NULL REFERENCES logistics.customer_return(id) ON DELETE CASCADE,
    line        smallint NOT NULL CHECK (line > 0),
    product_id  integer NOT NULL REFERENCES base.product(id),
    quantity    numeric(14,3) NOT NULL CHECK (quantity > 0),
    unit_price  numeric(14,2) NOT NULL CHECK (unit_price >= 0),
    PRIMARY KEY (return_id, line)
);
CREATE INDEX return_line_product_idx ON logistics.return_line (product_id);

-- Shipped quantities stop being reserved when stock leaves at shipment.
CREATE OR REPLACE VIEW inventory.reserved AS
SELECT product_id, warehouse_id, sum(quantity) AS quantity FROM (
    SELECT i.product_id, o.warehouse_id,
           greatest(i.quantity - CASE WHEN (SELECT stock_out_on FROM logistics.policy WHERE id = 1) = 'shipment'
               THEN COALESCE((SELECT sum(l.quantity) FROM logistics.shipment_line l JOIN logistics.shipment s ON s.id = l.shipment_id
                              WHERE s.sales_order_id = o.id AND l.order_line = i.line AND s.stock_moved), 0) ELSE 0 END, 0) AS quantity
    FROM sales.sales_order_item i JOIN sales.sales_order o ON o.id = i.order_id WHERE o.status = 'OPEN'
    UNION ALL
    SELECT c.product_id, w.warehouse_id, greatest(c.reserved_qty - c.issued_qty, 0)
    FROM production.order_component c JOIN production.work_order w ON w.id = c.order_id
    WHERE w.status IN ('released', 'in_progress')
) r GROUP BY product_id, warehouse_id;

-- ---------------------------------------------------------------- field service
CREATE TABLE field.sla_policy (
    priority text PRIMARY KEY CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
    hours    integer NOT NULL CHECK (hours BETWEEN 1 AND 2000)
);
INSERT INTO field.sla_policy (priority, hours) VALUES ('low', 72), ('normal', 24), ('high', 4), ('urgent', 2)
ON CONFLICT DO NOTHING;
CREATE TABLE field.customer_sla (
    customer_id integer NOT NULL REFERENCES base.party(id),
    priority    text NOT NULL REFERENCES field.sla_policy(priority),
    hours       integer NOT NULL CHECK (hours BETWEEN 1 AND 2000),
    PRIMARY KEY (customer_id, priority)
);
CREATE INDEX customer_sla_priority_idx ON field.customer_sla (priority);

CREATE TABLE field.technician (
    employee_id  integer PRIMARY KEY REFERENCES projects.employee(id),
    warehouse_id integer REFERENCES inventory.warehouse(id),
    active       boolean NOT NULL DEFAULT true
);
CREATE INDEX technician_warehouse_idx ON field.technician (warehouse_id);

-- RF-015-05
CREATE SEQUENCE field.order_number START 1;
CREATE TABLE field.service_order (
    id                 serial PRIMARY KEY,
    number             bigint NOT NULL UNIQUE DEFAULT nextval('field.order_number'),
    customer_id        integer NOT NULL REFERENCES base.party(id),
    site_address       text NOT NULL DEFAULT '',
    contact            text NOT NULL DEFAULT '',
    latitude           numeric(9,6) CHECK (latitude BETWEEN -90 AND 90),
    longitude          numeric(9,6) CHECK (longitude BETWEEN -180 AND 180),
    service_product_id integer REFERENCES base.product(id),
    equipment          text,
    serial_number      text,
    priority           text NOT NULL DEFAULT 'normal' REFERENCES field.sla_policy(priority),
    description        text NOT NULL CHECK (length(description) >= 3),
    project_id         integer REFERENCES projects.project(id),
    task_id            integer REFERENCES projects.task(id),
    status             text NOT NULL DEFAULT 'open'
                       CHECK (status IN ('open', 'scheduled', 'en_route', 'in_progress', 'done', 'invoiced', 'cancelled')),
    opened_at          timestamptz NOT NULL DEFAULT now(),
    due_at             timestamptz NOT NULL,
    first_visit_at     timestamptz,
    done_at            timestamptz,
    invoiced_at        timestamptz,
    entry_id           bigint REFERENCES finance.journal_entry(id),
    bill_id            bigint REFERENCES finance.bill(id),
    client_key         text UNIQUE,
    created_by         text NOT NULL,
    CHECK (task_id IS NULL OR project_id IS NOT NULL)
);
CREATE INDEX service_order_customer_idx ON field.service_order (customer_id);
CREATE INDEX service_order_status_idx ON field.service_order (status) WHERE status NOT IN ('invoiced', 'cancelled');
CREATE INDEX service_order_project_idx ON field.service_order (project_id);
CREATE INDEX service_order_task_idx ON field.service_order (task_id);
CREATE INDEX service_order_product_idx ON field.service_order (service_product_id);
CREATE INDEX service_order_entry_idx ON field.service_order (entry_id);
CREATE INDEX service_order_bill_idx ON field.service_order (bill_id);
CREATE INDEX service_order_opened_brin ON field.service_order USING brin (opened_at);

CREATE FUNCTION field.order_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN (
        ('open', 'scheduled'), ('open', 'cancelled'), ('open', 'en_route'), ('open', 'in_progress'),
        ('scheduled', 'en_route'), ('scheduled', 'in_progress'), ('scheduled', 'cancelled'), ('scheduled', 'open'),
        ('en_route', 'in_progress'), ('in_progress', 'done'), ('done', 'invoiced'))) THEN
        RAISE EXCEPTION 'INVALID_STATE: OS % não pode passar de % para %', OLD.number, OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status IN ('invoiced', 'cancelled') THEN
        RAISE EXCEPTION 'ORDER_CLOSED: OS % está %', OLD.number, OLD.status USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER service_order_guard BEFORE UPDATE ON field.service_order
    FOR EACH ROW EXECUTE FUNCTION field.order_guard();

-- RF-015-06 / RNF-015-01: no technician in two places at once.
CREATE TABLE field.assignment (
    id          bigserial PRIMARY KEY,
    order_id    integer NOT NULL REFERENCES field.service_order(id),
    employee_id integer NOT NULL REFERENCES projects.employee(id),
    period      tstzrange NOT NULL CHECK (NOT isempty(period) AND lower(period) IS NOT NULL AND upper(period) IS NOT NULL),
    travel_min  integer NOT NULL DEFAULT 0 CHECK (travel_min BETWEEN 0 AND 1440),
    distance_km numeric(8,1) CHECK (distance_km >= 0),
    seq         smallint,
    status      text NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'done', 'cancelled')),
    created_by  text NOT NULL,
    EXCLUDE USING gist (employee_id WITH =, period WITH &&) WHERE (status <> 'cancelled')
);
CREATE INDEX assignment_order_idx ON field.assignment (order_id);
CREATE INDEX assignment_period_idx ON field.assignment USING gist (period);

CREATE FUNCTION field.assignment_absence_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status <> 'cancelled' AND EXISTS (
        SELECT 1 FROM projects.absence a WHERE a.employee_id = NEW.employee_id
          AND daterange(a.from_date, a.to_date, '[]') && daterange(lower(NEW.period)::date, upper(NEW.period)::date, '[]')) THEN
        RAISE EXCEPTION 'TECHNICIAN_ABSENT: o técnico está ausente nesse período' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER assignment_absence_guard BEFORE INSERT OR UPDATE OF period, employee_id, status ON field.assignment
    FOR EACH ROW EXECUTE FUNCTION field.assignment_absence_guard();

-- RF-015-08: everything sent by the technician's app carries a client key (idempotent).
CREATE TABLE field.work_log (
    id          bigserial PRIMARY KEY,
    order_id    integer NOT NULL REFERENCES field.service_order(id),
    employee_id integer NOT NULL REFERENCES projects.employee(id),
    kind        text NOT NULL CHECK (kind IN ('travel', 'work')),
    hours       numeric(6,2) NOT NULL CHECK (hours > 0 AND hours <= 24),
    km          numeric(8,1) NOT NULL DEFAULT 0 CHECK (km >= 0),
    note        text NOT NULL DEFAULT '',
    client_key  text UNIQUE,
    logged_at   timestamptz NOT NULL DEFAULT now(),
    created_by  text NOT NULL
);
CREATE INDEX work_log_order_idx ON field.work_log (order_id);
CREATE INDEX work_log_employee_idx ON field.work_log (employee_id, logged_at);

CREATE TABLE field.part_usage (
    id                bigserial PRIMARY KEY,
    order_id          integer NOT NULL REFERENCES field.service_order(id),
    product_id        integer NOT NULL REFERENCES base.product(id),
    quantity          numeric(14,3) NOT NULL CHECK (quantity > 0),
    unit_price        numeric(14,2) NOT NULL CHECK (unit_price >= 0),
    warehouse_id      integer NOT NULL REFERENCES inventory.warehouse(id),
    stock_movement_id bigint REFERENCES inventory.stock_movement(id),
    client_key        text UNIQUE,
    created_by        text NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX part_usage_order_idx ON field.part_usage (order_id);
CREATE INDEX part_usage_product_idx ON field.part_usage (product_id);
CREATE INDEX part_usage_warehouse_idx ON field.part_usage (warehouse_id);
CREATE INDEX part_usage_movement_idx ON field.part_usage (stock_movement_id);

CREATE TABLE field.checklist_template (
    service_product_id integer NOT NULL REFERENCES base.product(id),
    item               smallint NOT NULL CHECK (item > 0),
    question           text NOT NULL,
    required           boolean NOT NULL DEFAULT true,
    PRIMARY KEY (service_product_id, item)
);
CREATE TABLE field.checklist_answer (
    order_id   integer NOT NULL REFERENCES field.service_order(id),
    item       smallint NOT NULL,
    answer     text NOT NULL,
    answered_by text NOT NULL,
    answered_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (order_id, item)
);
CREATE TABLE field.sign_off (
    order_id   integer PRIMARY KEY REFERENCES field.service_order(id),
    signed_by  text NOT NULL CHECK (length(signed_by) >= 2),
    document   text,
    notes      text NOT NULL DEFAULT '',
    signed_at  timestamptz NOT NULL DEFAULT now(),
    recorded_by text NOT NULL
);
CREATE TABLE field.invoice_line (
    order_id    integer NOT NULL REFERENCES field.service_order(id),
    line        smallint NOT NULL,
    kind        text NOT NULL CHECK (kind IN ('hours', 'travel', 'parts')),
    description text NOT NULL,
    quantity    numeric(14,3) NOT NULL,
    unit_price  numeric(14,2) NOT NULL,
    amount      numeric(14,2) NOT NULL,
    PRIMARY KEY (order_id, line)
);

DO $$
DECLARE s text;
BEGIN
    FOREACH s IN ARRAY ARRAY['logistics', 'field'] LOOP
        EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', s);
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO ana_exec, ana_read', s);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO ana_exec', s);
        EXECUTE format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO ana_exec', s);
        EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO ana_read', s);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ana_exec', s);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT USAGE, SELECT ON SEQUENCES TO ana_exec', s);
    END LOOP;
    GRANT SELECT ON inventory.reserved TO ana_exec, ana_read;
    REVOKE EXECUTE ON FUNCTION logistics.shipment_line_guard(), field.order_guard(), field.assignment_absence_guard() FROM PUBLIC;
END $$;
