-- 025 — Production and capacity planning (spec 014)

CREATE SCHEMA IF NOT EXISTS production;

INSERT INTO finance.account (code, description, nature, postable, cost_center_policy) VALUES
    ('1.1.5', 'Produtos em elaboração', 'asset', true, 'none'),
    ('5.3.1', 'Custos de produção absorvidos', 'expense', true, 'required')
ON CONFLICT DO NOTHING;
INSERT INTO finance.default_account (key, account, description) VALUES
    ('work_in_process', '1.1.5', 'Produtos em elaboração (ordens de produção abertas)'),
    ('production_absorbed', '5.3.1', 'Horas de recursos absorvidas pelas ordens de produção')
ON CONFLICT DO NOTHING;

CREATE TABLE production.policy (
    id                  integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    issue_tolerance_pct numeric(5,2) NOT NULL DEFAULT 10 CHECK (issue_tolerance_pct BETWEEN 0 AND 100)
);
INSERT INTO production.policy (id) VALUES (1) ON CONFLICT DO NOTHING;

-- Planning parameters per item.
CREATE TABLE production.item_plan (
    product_id     integer PRIMARY KEY REFERENCES base.product(id),
    make_or_buy    text NOT NULL DEFAULT 'buy' CHECK (make_or_buy IN ('make', 'buy')),
    lead_time_days integer NOT NULL DEFAULT 0 CHECK (lead_time_days BETWEEN 0 AND 730),
    lot_min        numeric(14,3) NOT NULL DEFAULT 0 CHECK (lot_min >= 0),
    lot_multiple   numeric(14,3) NOT NULL DEFAULT 0 CHECK (lot_multiple >= 0),
    safety_stock   numeric(14,3) NOT NULL DEFAULT 0 CHECK (safety_stock >= 0),
    warehouse_id   integer REFERENCES inventory.warehouse(id),
    standard_cost  numeric(14,4) CHECK (standard_cost >= 0)
);
CREATE INDEX item_plan_warehouse_idx ON production.item_plan (warehouse_id);

-- RF-014-01
CREATE TABLE production.structure (
    id          serial PRIMARY KEY,
    product_id  integer NOT NULL REFERENCES base.product(id),
    version     integer NOT NULL CHECK (version > 0),
    valid_from  date NOT NULL DEFAULT current_date,
    active      boolean NOT NULL DEFAULT true,
    notes       text NOT NULL DEFAULT '',
    created_by  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (product_id, version)
);
CREATE UNIQUE INDEX structure_active_uk ON production.structure (product_id) WHERE active;

CREATE TABLE production.structure_line (
    structure_id integer NOT NULL REFERENCES production.structure(id) ON DELETE CASCADE,
    line         smallint NOT NULL CHECK (line > 0),
    component_id integer NOT NULL REFERENCES base.product(id),
    quantity     numeric(14,6) NOT NULL CHECK (quantity > 0),
    scrap_pct    numeric(5,2) NOT NULL DEFAULT 0 CHECK (scrap_pct BETWEEN 0 AND 100),
    phantom      boolean NOT NULL DEFAULT false,
    PRIMARY KEY (structure_id, line)
);
CREATE INDEX structure_line_component_idx ON production.structure_line (component_id);

-- RNF-014-03 / CA-014-02: an item may never contain itself, at any depth.
CREATE FUNCTION production.structure_cycle_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_parent integer;
    v_struct integer;
    v_hit integer;
BEGIN
    IF TG_TABLE_NAME = 'structure' THEN
        IF NOT NEW.active THEN RETURN NEW; END IF;
        v_parent := NEW.product_id;
        v_struct := NEW.id;
    ELSE
        v_struct := NEW.structure_id;
        SELECT product_id INTO v_parent FROM production.structure WHERE id = v_struct;
    END IF;
    WITH RECURSIVE down AS (
        SELECT l.component_id, 1 AS depth FROM production.structure_line l
        JOIN production.structure s ON s.id = l.structure_id
        WHERE s.product_id = v_parent AND (s.active OR s.id = v_struct)
        UNION
        SELECT l.component_id, d.depth + 1 FROM down d
        JOIN production.structure s ON s.product_id = d.component_id AND s.active
        JOIN production.structure_line l ON l.structure_id = s.id
        WHERE d.depth < 50
    )
    SELECT component_id INTO v_hit FROM down WHERE component_id = v_parent LIMIT 1;
    IF v_hit IS NOT NULL THEN
        RAISE EXCEPTION 'STRUCTURE_CYCLE: a estrutura faria o item conter a si mesmo'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
-- Immediate (not deferred): the error reaches the program with its code, line by line.
CREATE TRIGGER structure_line_cycle AFTER INSERT OR UPDATE ON production.structure_line
    FOR EACH ROW EXECUTE FUNCTION production.structure_cycle_guard();
CREATE TRIGGER structure_cycle AFTER INSERT OR UPDATE OF active ON production.structure
    FOR EACH ROW EXECUTE FUNCTION production.structure_cycle_guard();

-- RF-014-03
CREATE TABLE production.resource (
    code           text PRIMARY KEY CHECK (code ~ '^[A-Z0-9_-]{1,30}$'),
    name           text NOT NULL,
    kind           text NOT NULL CHECK (kind IN ('machine', 'bench', 'line', 'people')),
    daily_hours    numeric(5,2) NOT NULL DEFAULT 8 CHECK (daily_hours BETWEEN 0 AND 24),
    efficiency_pct numeric(5,2) NOT NULL DEFAULT 100 CHECK (efficiency_pct BETWEEN 1 AND 200),
    cost_per_hour  numeric(12,2) NOT NULL DEFAULT 0 CHECK (cost_per_hour >= 0),
    profile        text REFERENCES projects.rate_profile(code),
    active         boolean NOT NULL DEFAULT true
);
CREATE INDEX resource_profile_idx ON production.resource (profile);

CREATE TABLE production.resource_calendar (
    resource_code text NOT NULL REFERENCES production.resource(code) ON UPDATE CASCADE ON DELETE CASCADE,
    day           date NOT NULL,
    hours         numeric(5,2) NOT NULL CHECK (hours BETWEEN 0 AND 24),
    reason        text NOT NULL DEFAULT '',
    PRIMARY KEY (resource_code, day)
);

-- RF-014-02
CREATE TABLE production.routing (
    id          serial PRIMARY KEY,
    product_id  integer NOT NULL REFERENCES base.product(id),
    version     integer NOT NULL CHECK (version > 0),
    active      boolean NOT NULL DEFAULT true,
    created_by  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (product_id, version)
);
CREATE UNIQUE INDEX routing_active_uk ON production.routing (product_id) WHERE active;

CREATE TABLE production.operation (
    routing_id    integer NOT NULL REFERENCES production.routing(id) ON DELETE CASCADE,
    seq           smallint NOT NULL CHECK (seq > 0),
    resource_code text NOT NULL REFERENCES production.resource(code) ON UPDATE CASCADE,
    description   text NOT NULL,
    setup_min     numeric(10,2) NOT NULL DEFAULT 0 CHECK (setup_min >= 0),
    run_min       numeric(10,3) NOT NULL DEFAULT 0 CHECK (run_min >= 0),
    PRIMARY KEY (routing_id, seq)
);
CREATE INDEX operation_resource_idx ON production.operation (resource_code);

-- RF-014-04
CREATE TABLE production.forecast (
    product_id integer NOT NULL REFERENCES base.product(id),
    week       date NOT NULL CHECK (extract(isodow FROM week) = 1),
    quantity   numeric(14,3) NOT NULL CHECK (quantity >= 0),
    PRIMARY KEY (product_id, week)
);

-- RF-014-05
CREATE TABLE production.planning_run (
    id            bigserial PRIMARY KEY,
    scenario      text NOT NULL DEFAULT 'principal' CHECK (scenario ~ '^[a-z0-9_-]{1,30}$'),
    horizon_weeks integer NOT NULL,
    status        text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'done', 'error')),
    suggestions   integer NOT NULL DEFAULT 0,
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    created_by    text NOT NULL
);
CREATE INDEX planning_run_scenario_idx ON production.planning_run (scenario, started_at DESC);

CREATE TABLE production.suggestion (
    id          bigserial PRIMARY KEY,
    run_id      bigint NOT NULL REFERENCES production.planning_run(id),
    scenario    text NOT NULL,
    kind        text NOT NULL CHECK (kind IN ('make', 'buy')),
    product_id  integer NOT NULL REFERENCES base.product(id),
    quantity    numeric(14,3) NOT NULL CHECK (quantity > 0),
    start_date  date NOT NULL,
    need_date   date NOT NULL,
    origin      jsonb NOT NULL DEFAULT '[]',
    status      text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'approved', 'discarded')),
    order_id    integer,
    request_id  integer,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX suggestion_scenario_status_idx ON production.suggestion (scenario, status);
CREATE INDEX suggestion_run_idx ON production.suggestion (run_id);
CREATE INDEX suggestion_product_idx ON production.suggestion (product_id);

-- RF-014-06 ("order" is a reserved word: work_order)
CREATE SEQUENCE production.order_number START 1;
CREATE TABLE production.work_order (
    id            serial PRIMARY KEY,
    number        bigint NOT NULL UNIQUE DEFAULT nextval('production.order_number'),
    product_id    integer NOT NULL REFERENCES base.product(id),
    quantity      numeric(14,3) NOT NULL CHECK (quantity > 0),
    structure_id  integer REFERENCES production.structure(id),
    routing_id    integer REFERENCES production.routing(id),
    warehouse_id  integer NOT NULL REFERENCES inventory.warehouse(id),
    start_date    date NOT NULL,
    due_date      date NOT NULL,
    priority      smallint NOT NULL DEFAULT 5 CHECK (priority BETWEEN 1 AND 9),
    project_id    integer REFERENCES projects.project(id),
    cost_center   text REFERENCES finance.cost_center(code) ON UPDATE CASCADE,
    status        text NOT NULL DEFAULT 'planned'
                  CHECK (status IN ('planned', 'released', 'in_progress', 'completed', 'closed', 'cancelled')),
    good_qty      numeric(14,3) NOT NULL DEFAULT 0 CHECK (good_qty >= 0),
    scrap_qty     numeric(14,3) NOT NULL DEFAULT 0 CHECK (scrap_qty >= 0),
    std_cost      numeric(14,2),
    actual_cost   numeric(14,2),
    variance      numeric(14,2),
    suggestion_id bigint REFERENCES production.suggestion(id),
    created_by    text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    released_at   timestamptz,
    closed_at     timestamptz,
    CHECK (due_date >= start_date)
);
CREATE INDEX work_order_product_idx ON production.work_order (product_id);
CREATE INDEX work_order_status_idx ON production.work_order (status) WHERE status NOT IN ('closed', 'cancelled');
CREATE INDEX work_order_project_idx ON production.work_order (project_id);
CREATE INDEX work_order_structure_idx ON production.work_order (structure_id);
CREATE INDEX work_order_routing_idx ON production.work_order (routing_id);
CREATE INDEX work_order_warehouse_idx ON production.work_order (warehouse_id);
CREATE INDEX work_order_cc_idx ON production.work_order (cost_center);
CREATE INDEX work_order_suggestion_idx ON production.work_order (suggestion_id);

CREATE TABLE production.order_component (
    order_id     integer NOT NULL REFERENCES production.work_order(id) ON DELETE CASCADE,
    line         smallint NOT NULL CHECK (line > 0),
    product_id   integer NOT NULL REFERENCES base.product(id),
    qty_required numeric(14,4) NOT NULL CHECK (qty_required > 0),
    reserved_qty numeric(14,4) NOT NULL DEFAULT 0 CHECK (reserved_qty >= 0),
    issued_qty   numeric(14,4) NOT NULL DEFAULT 0 CHECK (issued_qty >= 0),
    unit_cost    numeric(14,4) NOT NULL DEFAULT 0,
    PRIMARY KEY (order_id, line)
);
CREATE INDEX order_component_product_idx ON production.order_component (product_id);

CREATE TABLE production.order_operation (
    order_id      integer NOT NULL REFERENCES production.work_order(id) ON DELETE CASCADE,
    seq           smallint NOT NULL,
    resource_code text NOT NULL REFERENCES production.resource(code) ON UPDATE CASCADE,
    description   text NOT NULL,
    std_hours     numeric(10,3) NOT NULL DEFAULT 0,
    actual_hours  numeric(10,3) NOT NULL DEFAULT 0 CHECK (actual_hours >= 0),
    good_qty      numeric(14,3) NOT NULL DEFAULT 0,
    scrap_qty     numeric(14,3) NOT NULL DEFAULT 0,
    cost_per_hour numeric(12,2) NOT NULL DEFAULT 0,
    PRIMARY KEY (order_id, seq)
);
CREATE INDEX order_operation_resource_idx ON production.order_operation (resource_code);

CREATE TABLE production.operation_report (
    id          bigserial PRIMARY KEY,
    order_id    integer NOT NULL REFERENCES production.work_order(id),
    seq         smallint NOT NULL,
    hours       numeric(10,3) NOT NULL CHECK (hours >= 0),
    good_qty    numeric(14,3) NOT NULL DEFAULT 0 CHECK (good_qty >= 0),
    scrap_qty   numeric(14,3) NOT NULL DEFAULT 0 CHECK (scrap_qty >= 0),
    cost        numeric(14,2) NOT NULL DEFAULT 0,
    entry_id    bigint REFERENCES finance.journal_entry(id),
    reported_by text NOT NULL,
    reported_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX operation_report_order_idx ON production.operation_report (order_id, seq);
CREATE INDEX operation_report_entry_idx ON production.operation_report (entry_id);

-- RNF-014-03: valid transitions; closed/cancelled orders are immutable (cost included).
CREATE FUNCTION production.order_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status IN ('closed', 'cancelled') THEN
        RAISE EXCEPTION 'ORDER_CLOSED: ordem % está %', OLD.number, OLD.status USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN (
        ('planned', 'released'), ('planned', 'cancelled'), ('released', 'in_progress'), ('released', 'cancelled'),
        ('released', 'completed'), ('in_progress', 'completed'), ('in_progress', 'cancelled'), ('completed', 'closed'))) THEN
        RAISE EXCEPTION 'INVALID_STATE: ordem % não pode passar de % para %', OLD.number, OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER work_order_guard BEFORE UPDATE ON production.work_order
    FOR EACH ROW EXECUTE FUNCTION production.order_guard();

-- Issued never above required × (1 + tolerance); nothing changes on closed orders.
CREATE FUNCTION production.component_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_status text;
    v_tol numeric;
BEGIN
    SELECT status INTO v_status FROM production.work_order WHERE id = COALESCE(NEW.order_id, OLD.order_id);
    IF v_status IN ('closed', 'cancelled') THEN
        RAISE EXCEPTION 'ORDER_CLOSED: ordem encerrada ou cancelada' USING ERRCODE = 'check_violation';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    IF TG_TABLE_NAME = 'order_component' THEN
        SELECT issue_tolerance_pct INTO v_tol FROM production.policy WHERE id = 1;
        IF NEW.issued_qty > NEW.qty_required * (1 + COALESCE(v_tol, 0) / 100) THEN
            RAISE EXCEPTION 'OVER_ISSUE: requisitado % acima do necessário % (tolerância %%%)', NEW.issued_qty,
                NEW.qty_required, COALESCE(v_tol, 0) USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER order_component_guard BEFORE INSERT OR UPDATE OR DELETE ON production.order_component
    FOR EACH ROW EXECUTE FUNCTION production.component_guard();
CREATE TRIGGER order_operation_guard BEFORE INSERT OR UPDATE OR DELETE ON production.order_operation
    FOR EACH ROW EXECUTE FUNCTION production.component_guard();

-- Reservations now include released production orders (shared with specs 013 and 015).
CREATE OR REPLACE VIEW inventory.reserved AS
SELECT product_id, warehouse_id, sum(quantity) AS quantity FROM (
    SELECT i.product_id, o.warehouse_id, i.quantity
    FROM sales.sales_order_item i JOIN sales.sales_order o ON o.id = i.order_id WHERE o.status = 'OPEN'
    UNION ALL
    SELECT c.product_id, w.warehouse_id, greatest(c.reserved_qty - c.issued_qty, 0)
    FROM production.order_component c JOIN production.work_order w ON w.id = c.order_id
    WHERE w.status IN ('released', 'in_progress')
) r GROUP BY product_id, warehouse_id;

DO $$
BEGIN
    REVOKE ALL ON SCHEMA production FROM PUBLIC;
    GRANT USAGE ON SCHEMA production TO ana_exec, ana_read;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA production TO ana_exec;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA production TO ana_exec;
    GRANT SELECT ON ALL TABLES IN SCHEMA production TO ana_read;
    ALTER DEFAULT PRIVILEGES IN SCHEMA production GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ana_exec;
    ALTER DEFAULT PRIVILEGES IN SCHEMA production GRANT USAGE, SELECT ON SEQUENCES TO ana_exec;
    GRANT SELECT ON inventory.reserved TO ana_exec, ana_read;
    REVOKE EXECUTE ON FUNCTION production.structure_cycle_guard(), production.order_guard(),
        production.component_guard() FROM PUBLIC;
END $$;
