-- 002 — Business modules (spec 006)

CREATE SCHEMA IF NOT EXISTS base;
CREATE SCHEMA IF NOT EXISTS inventory;
CREATE SCHEMA IF NOT EXISTS sales;
CREATE SCHEMA IF NOT EXISTS finance;

-- ---------------------------------------------------------------- base
CREATE TABLE base.company (
    id          serial PRIMARY KEY,
    legal_name  text NOT NULL,
    tax_id      text NOT NULL UNIQUE,
    address     text,
    city        text,
    state       text,
    email       text,
    phone       text,
    created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE base.company IS 'Empresas operadas pelo ERP';

CREATE TABLE base.party (
    id          serial PRIMARY KEY,
    kind        text NOT NULL CHECK (kind IN ('customer', 'supplier', 'both')),
    name        text NOT NULL CHECK (length(name) BETWEEN 2 AND 200),
    tax_id      text UNIQUE,
    email       text,
    city        text,
    state       text,
    active      boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE base.party IS 'Clientes e fornecedores';

CREATE TABLE base.product (
    id          serial PRIMARY KEY,
    code        text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9_-]{1,30}$'),
    description text NOT NULL,
    unit        text NOT NULL DEFAULT 'UN',
    price       numeric(14,2) NOT NULL CHECK (price >= 0),
    active      boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE base.product IS 'Itens vendáveis/consumíveis';
COMMENT ON COLUMN base.product.price IS 'Preço de venda unitário';

-- ---------------------------------------------------------------- inventory
CREATE TABLE inventory.warehouse (
    id          serial PRIMARY KEY,
    code        text NOT NULL UNIQUE,
    description text NOT NULL
);

CREATE TABLE inventory.stock_movement (
    id           bigserial PRIMARY KEY,
    product_id   integer NOT NULL REFERENCES base.product(id),
    warehouse_id integer NOT NULL REFERENCES inventory.warehouse(id),
    quantity     numeric(14,3) NOT NULL CHECK (quantity <> 0),
    kind         text NOT NULL CHECK (kind IN ('in', 'out', 'adjustment')),
    document     text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   text NOT NULL
);
COMMENT ON TABLE inventory.stock_movement IS 'Movimentos de estoque; saldo = soma das quantidades';
CREATE INDEX stock_movement_product_idx ON inventory.stock_movement (product_id, warehouse_id);
CREATE INDEX stock_movement_warehouse_idx ON inventory.stock_movement (warehouse_id);
CREATE INDEX stock_movement_document_idx ON inventory.stock_movement (document);
CREATE INDEX stock_movement_created_brin ON inventory.stock_movement USING brin (created_at);

-- ---------------------------------------------------------------- sales
CREATE SEQUENCE sales.order_number START 1000;

CREATE TABLE sales.sales_order (
    id           serial PRIMARY KEY,
    number       bigint NOT NULL UNIQUE DEFAULT nextval('sales.order_number'),
    customer_id  integer NOT NULL REFERENCES base.party(id),
    warehouse_id integer NOT NULL REFERENCES inventory.warehouse(id),
    order_date   date NOT NULL DEFAULT current_date,
    status       text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'INVOICED', 'CANCELLED')),
    total        numeric(14,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   text NOT NULL,
    invoiced_at  timestamptz
);
CREATE INDEX sales_order_customer_idx ON sales.sales_order (customer_id);
CREATE INDEX sales_order_warehouse_idx ON sales.sales_order (warehouse_id);
CREATE INDEX sales_order_date_brin ON sales.sales_order USING brin (order_date);
CREATE INDEX sales_order_open_idx ON sales.sales_order (status) WHERE status = 'OPEN';

CREATE TABLE sales.sales_order_item (
    order_id    integer NOT NULL REFERENCES sales.sales_order(id) ON DELETE CASCADE,
    line        smallint NOT NULL CHECK (line > 0),
    product_id  integer NOT NULL REFERENCES base.product(id),
    quantity    numeric(14,3) NOT NULL CHECK (quantity > 0),
    price       numeric(14,2) NOT NULL CHECK (price >= 0),
    amount      numeric(14,2) GENERATED ALWAYS AS (round(quantity * price, 2)) STORED,
    PRIMARY KEY (order_id, line)
);
CREATE INDEX sales_order_item_product_idx ON sales.sales_order_item (product_id);

-- RF-006-03: items only on OPEN orders; total kept by the database.
CREATE FUNCTION sales.item_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_status text;
    v_order integer := COALESCE(NEW.order_id, OLD.order_id);
BEGIN
    SELECT status INTO v_status FROM sales.sales_order WHERE id = v_order;
    IF v_status IS DISTINCT FROM 'OPEN' THEN
        RAISE EXCEPTION 'pedido % não está OPEN', v_order USING ERRCODE = 'check_violation';
    END IF;
    RETURN COALESCE(NEW, OLD);
END $$;

CREATE FUNCTION sales.item_total() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_order integer := COALESCE(NEW.order_id, OLD.order_id);
BEGIN
    UPDATE sales.sales_order
       SET total = (SELECT COALESCE(sum(amount), 0) FROM sales.sales_order_item WHERE order_id = v_order)
     WHERE id = v_order;
    RETURN NULL;
END $$;

CREATE TRIGGER sales_order_item_check BEFORE INSERT OR UPDATE OR DELETE ON sales.sales_order_item
    FOR EACH ROW EXECUTE FUNCTION sales.item_check();
CREATE TRIGGER sales_order_item_total AFTER INSERT OR UPDATE OR DELETE ON sales.sales_order_item
    FOR EACH ROW EXECUTE FUNCTION sales.item_total();

-- ---------------------------------------------------------------- finance
CREATE TABLE finance.account (
    code        text PRIMARY KEY CHECK (code ~ '^[0-9]+(\.[0-9]+)*$'),
    description text NOT NULL,
    nature      text NOT NULL CHECK (nature IN ('asset', 'liability', 'equity', 'revenue', 'expense')),
    postable    boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE finance.account IS 'Plano de contas';

CREATE TABLE finance.journal_entry (
    id          bigserial PRIMARY KEY,
    entry_date  date NOT NULL DEFAULT current_date,
    memo        text NOT NULL,
    document    text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text NOT NULL
);
CREATE INDEX journal_entry_date_brin ON finance.journal_entry USING brin (entry_date);

CREATE TABLE finance.journal_line (
    id          bigserial PRIMARY KEY,
    entry_id    bigint NOT NULL REFERENCES finance.journal_entry(id) ON DELETE CASCADE,
    account     text NOT NULL REFERENCES finance.account(code),
    debit       numeric(14,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
    credit      numeric(14,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
    CHECK ((debit > 0) <> (credit > 0))
);
CREATE INDEX journal_line_entry_idx ON finance.journal_line (entry_id);
CREATE INDEX journal_line_account_idx ON finance.journal_line (account);

-- RF-006-05: double entry, checked at COMMIT (deferred constraint trigger).
CREATE FUNCTION finance.entry_balanced() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_id bigint := COALESCE(NEW.entry_id, OLD.entry_id);
    v_debit numeric; v_credit numeric;
BEGIN
    SELECT COALESCE(sum(debit), 0), COALESCE(sum(credit), 0) INTO v_debit, v_credit
      FROM finance.journal_line WHERE entry_id = v_id;
    IF v_debit <> v_credit THEN
        RAISE EXCEPTION 'lançamento % desbalanceado: débitos % ≠ créditos %', v_id, v_debit, v_credit
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER journal_line_balanced
    AFTER INSERT OR UPDATE OR DELETE ON finance.journal_line
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION finance.entry_balanced();

CREATE TABLE finance.bill (
    id          bigserial PRIMARY KEY,
    kind        text NOT NULL CHECK (kind IN ('receivable', 'payable')),
    party_id    integer NOT NULL REFERENCES base.party(id),
    document    text NOT NULL,
    issue_date  date NOT NULL DEFAULT current_date,
    due_date    date NOT NULL,
    amount      numeric(14,2) NOT NULL CHECK (amount > 0),
    status      text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'settled', 'cancelled')),
    entry_id    bigint REFERENCES finance.journal_entry(id),
    CHECK (due_date >= issue_date)
);
CREATE INDEX bill_party_idx ON finance.bill (party_id);
CREATE INDEX bill_entry_idx ON finance.bill (entry_id);
CREATE INDEX bill_document_idx ON finance.bill (document);
CREATE INDEX bill_due_idx ON finance.bill (due_date) WHERE status = 'open';

-- ---------------------------------------------------------------- privileges
-- RNF-006-03: ana_exec does DML, never DDL. ana_read only reads.
DO $$
DECLARE s text;
BEGIN
    FOREACH s IN ARRAY ARRAY['base', 'inventory', 'sales', 'finance'] LOOP
        EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', s);
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO ana_exec, ana_read', s);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO ana_exec', s);
        EXECUTE format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO ana_exec', s);
        EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO ana_read', s);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ana_exec', s);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT USAGE, SELECT ON SEQUENCES TO ana_exec', s);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON TABLES TO ana_read', s);
    END LOOP;
    REVOKE EXECUTE ON FUNCTION sales.item_check(), sales.item_total(), finance.entry_balanced() FROM PUBLIC;
END $$;
