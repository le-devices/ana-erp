-- 018 — Cost centers integrated into accounting (spec 027)

CREATE TABLE finance.cost_center (
    code        text PRIMARY KEY CHECK (code ~ '^[A-Z0-9_.-]{1,30}$'),
    name        text NOT NULL CHECK (length(name) BETWEEN 2 AND 120),
    parent_code text REFERENCES finance.cost_center(code) ON UPDATE CASCADE,
    kind        text NOT NULL DEFAULT 'operational'
                CHECK (kind IN ('operational', 'administrative', 'commercial', 'project', 'other')),
    manager     text,
    active      boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (parent_code IS NULL OR parent_code <> code)
);
CREATE INDEX cost_center_parent_idx ON finance.cost_center (parent_code);
COMMENT ON TABLE finance.cost_center IS 'Centros de custo (hierarquia); o produto traz só GERAL';
INSERT INTO finance.cost_center (code, name, kind) VALUES ('GERAL', 'Geral', 'other') ON CONFLICT DO NOTHING;

-- Defaults by key (P13: adjustable per client). company = when nothing else applies.
CREATE TABLE finance.default_cost_center (
    key         text PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]*$'),
    cost_center text NOT NULL REFERENCES finance.cost_center(code) ON UPDATE CASCADE
);
CREATE INDEX default_cost_center_cc_idx ON finance.default_cost_center (cost_center);
INSERT INTO finance.default_cost_center (key, cost_center) VALUES ('company', 'GERAL') ON CONFLICT DO NOTHING;

-- RF-027-02: policy per account.
ALTER TABLE finance.account ADD COLUMN cost_center_policy text NOT NULL DEFAULT 'none'
    CHECK (cost_center_policy IN ('none', 'optional', 'required'));
UPDATE finance.account SET cost_center_policy = 'required' WHERE nature IN ('revenue', 'expense') AND postable;

ALTER TABLE finance.journal_line ADD COLUMN cost_center text REFERENCES finance.cost_center(code) ON UPDATE CASCADE;
CREATE INDEX journal_line_cost_center_idx ON finance.journal_line (cost_center, account);

-- Default of the document being posted: SELECT set_config('ana.cost_center', 'ENG', true) in the program.
CREATE FUNCTION finance.journal_line_cost_center() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_policy text;
    v_active boolean;
BEGIN
    SELECT cost_center_policy INTO v_policy FROM finance.account WHERE code = NEW.account;
    IF v_policy = 'none' THEN
        IF NEW.cost_center IS NOT NULL THEN
            RAISE EXCEPTION 'COST_CENTER_NOT_ALLOWED: a conta % não aceita centro de custo', NEW.account
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.cost_center IS NULL AND v_policy = 'required' THEN
        NEW.cost_center := COALESCE(NULLIF(current_setting('ana.cost_center', true), ''),
                                    (SELECT cost_center FROM finance.default_cost_center WHERE key = 'company'));
        IF NEW.cost_center IS NULL THEN
            RAISE EXCEPTION 'COST_CENTER_REQUIRED: a conta % exige centro de custo', NEW.account
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF NEW.cost_center IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.cost_center IS DISTINCT FROM OLD.cost_center) THEN
        SELECT active INTO v_active FROM finance.cost_center WHERE code = NEW.cost_center;
        IF v_active IS DISTINCT FROM true THEN
            RAISE EXCEPTION 'COST_CENTER_INACTIVE: centro de custo % inexistente ou inativo', NEW.cost_center
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER journal_line_cost_center BEFORE INSERT OR UPDATE OF account, cost_center ON finance.journal_line
    FOR EACH ROW EXECUTE FUNCTION finance.journal_line_cost_center();

-- Lines posted before cost centers existed go to the company default.
UPDATE finance.journal_line l SET cost_center = 'GERAL'
FROM finance.account a WHERE a.code = l.account AND a.cost_center_policy = 'required' AND l.cost_center IS NULL;

-- RF-027-03: where the cost center of a document comes from.
ALTER TABLE projects.project ADD COLUMN cost_center text REFERENCES finance.cost_center(code) ON UPDATE CASCADE;
ALTER TABLE sales.sales_order ADD COLUMN cost_center text REFERENCES finance.cost_center(code) ON UPDATE CASCADE;
ALTER TABLE inventory.warehouse ADD COLUMN cost_center text REFERENCES finance.cost_center(code) ON UPDATE CASCADE;
CREATE INDEX project_cost_center_idx ON projects.project (cost_center);
CREATE INDEX sales_order_cost_center_idx ON sales.sales_order (cost_center);
CREATE INDEX warehouse_cost_center_idx ON inventory.warehouse (cost_center);

-- RF-027-05
CREATE TABLE finance.cost_center_budget (
    cost_center text NOT NULL REFERENCES finance.cost_center(code) ON UPDATE CASCADE,
    account     text NOT NULL REFERENCES finance.account(code),
    month       date NOT NULL CHECK (extract(day FROM month) = 1),
    amount      numeric(14,2) NOT NULL,
    PRIMARY KEY (cost_center, account, month)
);
CREATE INDEX cost_center_budget_account_idx ON finance.cost_center_budget (account);

-- RF-027-06
CREATE TABLE finance.allocation_rule (
    code           text PRIMARY KEY CHECK (code ~ '^[A-Z0-9_-]{1,30}$'),
    name           text NOT NULL,
    source         text NOT NULL REFERENCES finance.cost_center(code) ON UPDATE CASCADE,
    account_prefix text NOT NULL DEFAULT '5',
    targets        jsonb NOT NULL CHECK (jsonb_typeof(targets) = 'array'),
    active         boolean NOT NULL DEFAULT true
);
CREATE INDEX allocation_rule_source_idx ON finance.allocation_rule (source);
-- One allocation entry per rule and month.
CREATE UNIQUE INDEX journal_entry_allocation_uk ON finance.journal_entry (document) WHERE document LIKE 'RATEIO-%';

DO $$
BEGIN
    GRANT SELECT, INSERT, UPDATE, DELETE ON finance.cost_center, finance.default_cost_center,
        finance.cost_center_budget, finance.allocation_rule TO ana_exec;
    GRANT SELECT ON finance.cost_center, finance.default_cost_center, finance.cost_center_budget,
        finance.allocation_rule TO ana_read;
    REVOKE EXECUTE ON FUNCTION finance.journal_line_cost_center() FROM PUBLIC;
END $$;
