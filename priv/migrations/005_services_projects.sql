-- 005 — Services and projects (spec 008)

-- ---------------------------------------------------------------- RF-008-01
ALTER TABLE base.product
    ADD COLUMN kind text NOT NULL DEFAULT 'goods' CHECK (kind IN ('goods', 'service'));
COMMENT ON COLUMN base.product.kind IS 'goods: controla estoque; service: não controla';

-- ---------------------------------------------------------------- RF-008-02 / P13
INSERT INTO finance.account (code, description, nature, postable) VALUES
    ('1.1.4', 'Imposto sobre serviços retido a compensar', 'asset', true),
    ('4.1.2', 'Receita de serviços', 'revenue', true)
ON CONFLICT DO NOTHING;

CREATE TABLE finance.default_account (
    key         text PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]*$'),
    account     text NOT NULL REFERENCES finance.account(code),
    description text NOT NULL DEFAULT ''
);
COMMENT ON TABLE finance.default_account IS 'Contas usadas pelos programas do produto; ajustável por cliente';
CREATE INDEX default_account_account_idx ON finance.default_account (account);
INSERT INTO finance.default_account (key, account, description) VALUES
    ('customers', '1.1.2', 'Contas a receber de clientes'),
    ('sales_revenue', '4.1.1', 'Receita de venda de mercadorias'),
    ('service_revenue', '4.1.2', 'Receita de prestação de serviços'),
    ('service_tax_withheld', '1.1.4', 'Imposto sobre serviços retido pelo tomador')
ON CONFLICT DO NOTHING;

CREATE FUNCTION finance.account_for(p_key text) RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE v text;
BEGIN
    SELECT account INTO v FROM finance.default_account WHERE key = p_key;
    IF v IS NULL THEN
        RAISE EXCEPTION 'conta padrão "%" não configurada em finance.default_account', p_key
            USING ERRCODE = 'no_data_found';
    END IF;
    RETURN v;
END $$;

-- ---------------------------------------------------------------- projects
CREATE SCHEMA IF NOT EXISTS projects;

CREATE TABLE projects.rate_profile (
    code        text PRIMARY KEY CHECK (code ~ '^[A-Z0-9_-]{1,20}$'),
    description text NOT NULL,
    hourly_rate numeric(12,2) NOT NULL CHECK (hourly_rate >= 0),
    active      boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE projects.rate_profile IS 'Perfis profissionais com valor-hora padrão de venda';

CREATE TABLE projects.employee (
    id          serial PRIMARY KEY,
    name        text NOT NULL CHECK (length(name) BETWEEN 2 AND 200),
    username    text UNIQUE,
    profile     text NOT NULL REFERENCES projects.rate_profile(code),
    hourly_cost numeric(12,2) NOT NULL DEFAULT 0 CHECK (hourly_cost >= 0),
    active      boolean NOT NULL DEFAULT true
);
COMMENT ON COLUMN projects.employee.hourly_cost IS 'Custo interno por hora (confidencial)';
CREATE INDEX employee_profile_idx ON projects.employee (profile);

CREATE SEQUENCE projects.invoice_number START 1;

CREATE TABLE projects.project (
    id                   serial PRIMARY KEY,
    code                 text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9_-]{1,30}$'),
    name                 text NOT NULL,
    customer_id          integer NOT NULL REFERENCES base.party(id),
    manager              text NOT NULL,
    billing              text NOT NULL DEFAULT 'hourly' CHECK (billing IN ('hourly', 'fixed', 'mixed')),
    status               text NOT NULL DEFAULT 'proposal'
                         CHECK (status IN ('proposal', 'active', 'suspended', 'closed')),
    start_date           date,
    due_date             date,
    budget_hours         numeric(10,2) CHECK (budget_hours >= 0),
    budget_amount        numeric(14,2) CHECK (budget_amount >= 0),
    service_tax_rate     numeric(5,4) NOT NULL DEFAULT 0 CHECK (service_tax_rate BETWEEN 0 AND 0.2),
    service_tax_withheld boolean NOT NULL DEFAULT false,
    description          text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    CHECK (due_date IS NULL OR start_date IS NULL OR due_date >= start_date)
);
CREATE INDEX project_customer_idx ON projects.project (customer_id);
CREATE INDEX project_manager_idx ON projects.project (manager);

CREATE TABLE projects.project_rate (
    project_id  integer NOT NULL REFERENCES projects.project(id) ON DELETE CASCADE,
    profile     text NOT NULL REFERENCES projects.rate_profile(code),
    hourly_rate numeric(12,2) NOT NULL CHECK (hourly_rate >= 0),
    PRIMARY KEY (project_id, profile)
);
CREATE INDEX project_rate_profile_idx ON projects.project_rate (profile);

CREATE TABLE projects.task (
    id            serial PRIMARY KEY,
    project_id    integer NOT NULL REFERENCES projects.project(id) ON DELETE CASCADE,
    code          text NOT NULL CHECK (code ~ '^[0-9A-Za-z._-]{1,20}$'),
    name          text NOT NULL,
    planned_hours numeric(10,2) CHECK (planned_hours >= 0),
    billable      boolean NOT NULL DEFAULT true,
    active        boolean NOT NULL DEFAULT true,
    UNIQUE (project_id, code)
);

CREATE TABLE projects.project_member (
    project_id  integer NOT NULL REFERENCES projects.project(id) ON DELETE CASCADE,
    employee_id integer NOT NULL REFERENCES projects.employee(id),
    profile     text NOT NULL REFERENCES projects.rate_profile(code),
    PRIMARY KEY (project_id, employee_id)
);
CREATE INDEX project_member_employee_idx ON projects.project_member (employee_id);
CREATE INDEX project_member_profile_idx ON projects.project_member (profile);

CREATE TABLE projects.invoice (
    id                   serial PRIMARY KEY,
    number               bigint NOT NULL UNIQUE DEFAULT nextval('projects.invoice_number'),
    project_id           integer NOT NULL REFERENCES projects.project(id),
    customer_id          integer NOT NULL REFERENCES base.party(id),
    issue_date           date NOT NULL DEFAULT current_date,
    through_date         date NOT NULL,
    total                numeric(14,2) NOT NULL CHECK (total > 0),
    service_tax_rate     numeric(5,4) NOT NULL DEFAULT 0,
    service_tax_amount   numeric(14,2) NOT NULL DEFAULT 0,
    service_tax_withheld boolean NOT NULL DEFAULT false,
    net_amount           numeric(14,2) NOT NULL,
    status               text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued', 'cancelled')),
    bill_id              bigint REFERENCES finance.bill(id),
    entry_id             bigint REFERENCES finance.journal_entry(id),
    reversal_entry_id    bigint REFERENCES finance.journal_entry(id),
    created_by           text NOT NULL,
    created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX invoice_project_idx ON projects.invoice (project_id);
CREATE INDEX invoice_customer_idx ON projects.invoice (customer_id);
CREATE INDEX invoice_bill_idx ON projects.invoice (bill_id);
CREATE INDEX invoice_entry_idx ON projects.invoice (entry_id);
CREATE INDEX invoice_reversal_idx ON projects.invoice (reversal_entry_id);

CREATE TABLE projects.invoice_line (
    invoice_id  integer NOT NULL REFERENCES projects.invoice(id) ON DELETE CASCADE,
    line        smallint NOT NULL,
    source      text NOT NULL CHECK (source IN ('hours', 'expense', 'milestone')),
    description text NOT NULL,
    quantity    numeric(12,3) NOT NULL,
    unit_price  numeric(14,2) NOT NULL,
    amount      numeric(14,2) NOT NULL,
    PRIMARY KEY (invoice_id, line)
);

CREATE TABLE projects.time_entry (
    id               bigserial PRIMARY KEY,
    project_id       integer NOT NULL REFERENCES projects.project(id),
    task_id          integer NOT NULL REFERENCES projects.task(id),
    employee_id      integer NOT NULL REFERENCES projects.employee(id),
    entry_date       date NOT NULL,
    hours            numeric(5,2) NOT NULL CHECK (hours > 0 AND hours <= 24 AND (hours * 4) = trunc(hours * 4)),
    description      text NOT NULL CHECK (length(trim(description)) >= 3),
    billable         boolean NOT NULL DEFAULT true,
    status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'approved', 'rejected', 'invoiced')),
    profile          text NOT NULL REFERENCES projects.rate_profile(code),
    hourly_rate      numeric(12,2),
    hourly_cost      numeric(12,2),
    rejection_reason text,
    approved_by      text,
    approved_at      timestamptz,
    invoice_id       integer REFERENCES projects.invoice(id),
    created_by       text NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (status NOT IN ('approved', 'invoiced') OR (hourly_rate IS NOT NULL AND hourly_cost IS NOT NULL)),
    CHECK ((status = 'invoiced') = (invoice_id IS NOT NULL))
);
CREATE INDEX time_entry_project_status_idx ON projects.time_entry (project_id, status);
CREATE INDEX time_entry_employee_date_idx ON projects.time_entry (employee_id, entry_date);
CREATE INDEX time_entry_task_idx ON projects.time_entry (task_id);
CREATE INDEX time_entry_invoice_idx ON projects.time_entry (invoice_id);
CREATE INDEX time_entry_profile_idx ON projects.time_entry (profile);
CREATE INDEX time_entry_date_brin ON projects.time_entry USING brin (entry_date);

CREATE TABLE projects.expense (
    id                bigserial PRIMARY KEY,
    project_id        integer NOT NULL REFERENCES projects.project(id),
    expense_date      date NOT NULL DEFAULT current_date,
    kind              text NOT NULL CHECK (kind IN ('component', 'pcb', 'supplies', 'subcontract', 'travel', 'other')),
    description       text NOT NULL,
    supplier_id       integer REFERENCES base.party(id),
    product_id        integer REFERENCES base.product(id),
    stock_movement_id bigint REFERENCES inventory.stock_movement(id),
    quantity          numeric(12,3) NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit_cost         numeric(14,4) NOT NULL CHECK (unit_cost >= 0),
    rebillable        boolean NOT NULL DEFAULT false,
    markup_pct        numeric(6,2) NOT NULL DEFAULT 0 CHECK (markup_pct BETWEEN 0 AND 1000),
    status            text NOT NULL DEFAULT 'posted' CHECK (status IN ('posted', 'invoiced')),
    invoice_id        integer REFERENCES projects.invoice(id),
    created_by        text NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    CHECK ((status = 'invoiced') = (invoice_id IS NOT NULL))
);
CREATE INDEX expense_project_status_idx ON projects.expense (project_id, status);
CREATE INDEX expense_supplier_idx ON projects.expense (supplier_id);
CREATE INDEX expense_product_idx ON projects.expense (product_id);
CREATE INDEX expense_movement_idx ON projects.expense (stock_movement_id);
CREATE INDEX expense_invoice_idx ON projects.expense (invoice_id);

CREATE TABLE projects.milestone (
    id           serial PRIMARY KEY,
    project_id   integer NOT NULL REFERENCES projects.project(id),
    description  text NOT NULL,
    amount       numeric(14,2) NOT NULL CHECK (amount > 0),
    due_date     date,
    completed_on date,
    status       text NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'completed', 'invoiced')),
    invoice_id   integer REFERENCES projects.invoice(id),
    CHECK ((status = 'invoiced') = (invoice_id IS NOT NULL)),
    CHECK ((status = 'planned') = (completed_on IS NULL))
);
CREATE INDEX milestone_project_status_idx ON projects.milestone (project_id, status);
CREATE INDEX milestone_invoice_idx ON projects.milestone (invoice_id);

-- ---------------------------------------------------------------- RNF-008-01
-- Approved/invoiced entries are immutable; only invoicing transitions pass.
CREATE FUNCTION projects.time_entry_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status IN ('approved', 'invoiced') THEN
            RAISE EXCEPTION 'apontamento % está % e não pode ser excluído', OLD.id, OLD.status
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.status IN ('approved', 'invoiced') THEN
        IF (OLD.project_id, OLD.task_id, OLD.employee_id, OLD.entry_date, OLD.hours, OLD.description,
            OLD.billable, OLD.profile, OLD.hourly_rate, OLD.hourly_cost, OLD.approved_by, OLD.approved_at)
           IS DISTINCT FROM
           (NEW.project_id, NEW.task_id, NEW.employee_id, NEW.entry_date, NEW.hours, NEW.description,
            NEW.billable, NEW.profile, NEW.hourly_rate, NEW.hourly_cost, NEW.approved_by, NEW.approved_at)
           OR NOT ((OLD.status = 'approved' AND NEW.status = 'invoiced')
                   OR (OLD.status = 'invoiced' AND NEW.status = 'approved')
                   OR (OLD.status = NEW.status AND OLD.invoice_id IS NOT DISTINCT FROM NEW.invoice_id))
        THEN
            RAISE EXCEPTION 'apontamento % está % e não pode ser alterado', OLD.id, OLD.status
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER time_entry_guard BEFORE UPDATE OR DELETE ON projects.time_entry
    FOR EACH ROW EXECUTE FUNCTION projects.time_entry_guard();

-- RF-008-07: at most 24 h per employee per day (serialized per employee).
CREATE FUNCTION projects.time_entry_daily_limit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_total numeric;
BEGIN
    IF NEW.status = 'rejected' THEN
        RETURN NEW;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('ana.time_entry'), NEW.employee_id);
    SELECT COALESCE(sum(hours), 0) INTO v_total
      FROM projects.time_entry
     WHERE employee_id = NEW.employee_id AND entry_date = NEW.entry_date
       AND status <> 'rejected' AND id <> NEW.id;
    IF v_total + NEW.hours > 24 THEN
        RAISE EXCEPTION 'DAILY_LIMIT: % h já apontadas em %', v_total, NEW.entry_date
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER time_entry_daily_limit BEFORE INSERT OR UPDATE OF hours, entry_date, employee_id, status
    ON projects.time_entry FOR EACH ROW EXECUTE FUNCTION projects.time_entry_daily_limit();

-- Invoiced expenses and milestones are immutable, except the invoicing reversal.
CREATE FUNCTION projects.invoiced_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.invoice_id IS NOT NULL THEN
            RAISE EXCEPTION '% % já faturado(a)', TG_TABLE_NAME, OLD.id USING ERRCODE = 'check_violation';
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.invoice_id IS NOT NULL
       AND (to_jsonb(OLD) - 'status' - 'invoice_id') IS DISTINCT FROM (to_jsonb(NEW) - 'status' - 'invoice_id') THEN
        RAISE EXCEPTION '% % já faturado(a)', TG_TABLE_NAME, OLD.id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER expense_guard BEFORE UPDATE OR DELETE ON projects.expense
    FOR EACH ROW EXECUTE FUNCTION projects.invoiced_guard();
CREATE TRIGGER milestone_guard BEFORE UPDATE OR DELETE ON projects.milestone
    FOR EACH ROW EXECUTE FUNCTION projects.invoiced_guard();

-- ---------------------------------------------------------------- privileges
DO $$
BEGIN
    REVOKE ALL ON SCHEMA projects FROM PUBLIC;
    GRANT USAGE ON SCHEMA projects TO ana_exec, ana_read;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA projects TO ana_exec;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA projects TO ana_exec;
    GRANT SELECT ON ALL TABLES IN SCHEMA projects TO ana_read;
    -- Hourly cost is confidential: the SQL console cannot read it (RNF-008-02).
    REVOKE SELECT ON projects.employee FROM ana_read;
    GRANT SELECT (id, name, username, profile, active) ON projects.employee TO ana_read;
    REVOKE SELECT ON projects.time_entry FROM ana_read;
    GRANT SELECT (id, project_id, task_id, employee_id, entry_date, hours, description, billable,
                  status, profile, hourly_rate, approved_by, approved_at, invoice_id, created_by, created_at)
        ON projects.time_entry TO ana_read;
    ALTER DEFAULT PRIVILEGES IN SCHEMA projects GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ana_exec;
    ALTER DEFAULT PRIVILEGES IN SCHEMA projects GRANT USAGE, SELECT ON SEQUENCES TO ana_exec;
    GRANT EXECUTE ON FUNCTION finance.account_for(text) TO ana_exec;
    REVOKE EXECUTE ON FUNCTION projects.time_entry_guard(), projects.time_entry_daily_limit(),
        projects.invoiced_guard() FROM PUBLIC;
END $$;
