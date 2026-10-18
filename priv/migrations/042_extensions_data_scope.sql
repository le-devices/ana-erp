-- Spec 009 phase 2: extension points (D9) and permission by data (D10).

-- ---------------------------------------------------------------- extension points (T-009-08)
-- A customer program registered for a point of a product program; runs in the same transaction.
CREATE TABLE ana_system.extension (
    id         bigserial PRIMARY KEY,
    point      text NOT NULL CHECK (point ~ '^(before|after)_[a-z_]+$'),
    program    text NOT NULL REFERENCES ana_system.program(name) ON DELETE CASCADE ON UPDATE CASCADE,
    position   integer NOT NULL DEFAULT 100,
    active     boolean NOT NULL DEFAULT true,
    created_by text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (point, program)
);
COMMENT ON TABLE ana_system.extension IS 'Programas do cliente ligados a pontos de extensão dos programas do produto';

CREATE FUNCTION ana_system.extension_changed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('ana_extension', '');
    RETURN NULL;
END $$;
CREATE TRIGGER extension_changed AFTER INSERT OR UPDATE OR DELETE ON ana_system.extension
    FOR EACH STATEMENT EXECUTE FUNCTION ana_system.extension_changed();

-- ---------------------------------------------------------------- permission by data (T-009-09)
-- Set on access groups; the core turns a user's groups into GUCs of each execution transaction
-- (ana.scope_cc, ana.scope_portfolio, ana.scope_projects). Administrators and users whose groups
-- set nothing see everything. Applied by the database (RLS), whatever program runs.
ALTER TABLE ana_system.access_group
    ADD COLUMN data_cost_centers text[],                           -- NULL = no restriction; children included
    ADD COLUMN data_portfolio boolean NOT NULL DEFAULT false,      -- only customers (and their documents) of the salesperson
    ADD COLUMN data_own_projects boolean NOT NULL DEFAULT false;   -- only projects managed or worked on

-- The salesperson of a customer (portfolio) and of each order (from the customer, else who created it).
ALTER TABLE base.party ADD COLUMN salesperson text;
CREATE INDEX party_salesperson_idx ON base.party (salesperson) WHERE salesperson IS NOT NULL;
ALTER TABLE sales.sales_order ADD COLUMN salesperson text;
CREATE INDEX sales_order_salesperson_idx ON sales.sales_order (salesperson) WHERE salesperson IS NOT NULL;
UPDATE sales.sales_order SET salesperson = created_by WHERE salesperson IS NULL;

CREATE FUNCTION sales.order_salesperson() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.salesperson IS NULL THEN
        NEW.salesperson := COALESCE((SELECT salesperson FROM base.party WHERE id = NEW.customer_id),
                                    NULLIF(current_setting('ana.username', true), ''), NEW.created_by);
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER sales_order_salesperson BEFORE INSERT ON sales.sales_order
    FOR EACH ROW EXECUTE FUNCTION sales.order_salesperson();

-- A customer created by someone limited to the portfolio belongs to that person's portfolio.
CREATE FUNCTION base.party_salesperson() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.salesperson IS NULL AND NEW.kind <> 'supplier'
       AND COALESCE(current_setting('ana.scope_portfolio', true), '') = 'on' THEN
        NEW.salesperson := NULLIF(current_setting('ana.username', true), '');
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER party_salesperson BEFORE INSERT ON base.party FOR EACH ROW EXECUTE FUNCTION base.party_salesperson();

-- Cheap checks (no GUC = no restriction). ana.scope_cc is ",A,B," (",," allows rows without center).
CREATE FUNCTION base.scope_cc(p_cc text) RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT s IS NULL OR s = '' OR position(',' || COALESCE(p_cc, '') || ',' IN s) > 0
      FROM (SELECT current_setting('ana.scope_cc', true) AS s) x
$$;
CREATE FUNCTION base.scope_portfolio() RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT COALESCE(current_setting('ana.scope_portfolio', true), '') = 'on'
$$;
CREATE FUNCTION base.scope_projects() RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT COALESCE(current_setting('ana.scope_projects', true), '') = 'on'
$$;

-- Restricted executions run as ana_scoped (SET LOCAL ROLE, set by the core only when the user has a
-- data scope): the policies are RESTRICTIVE and apply to that role alone, so every other execution keeps
-- the same plans and pays nothing. ana_scoped has the same privileges as ana_exec (copied by
-- ana_system.sync_scoped_role(), run after every migration).
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ana_scoped') THEN
        CREATE ROLE ana_scoped NOLOGIN NOINHERIT;
    END IF;
END $$;
GRANT ana_scoped TO ana_exec;

CREATE FUNCTION ana_system.sync_scoped_role() RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    r record;
    n integer := 0;
BEGIN
    FOR r IN SELECT n.nspname FROM pg_namespace n
              WHERE has_schema_privilege('ana_exec', n.oid, 'USAGE') AND n.nspname NOT LIKE 'pg\_%'
                AND n.nspname NOT IN ('information_schema', 'citus', 'citus_internal', 'columnar', 'columnar_internal') LOOP
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO ana_scoped', r.nspname); n := n + 1;
    END LOOP;
    FOR r IN SELECT c.oid, n.nspname, c.relname, c.relkind, p.priv FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) AS p(priv)
              WHERE c.relkind IN ('r', 'v', 'm', 'p', 'f') AND n.nspname NOT LIKE 'pg\_%'
                AND n.nspname NOT IN ('information_schema', 'citus', 'citus_internal', 'columnar', 'columnar_internal')
                AND has_table_privilege('ana_exec', c.oid, p.priv) LOOP
        EXECUTE format('GRANT %s ON TABLE %I.%I TO ana_scoped', r.priv, r.nspname, r.relname); n := n + 1;
    END LOOP;
    FOR r IN SELECT n.nspname, c.relname, p.priv FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             CROSS JOIN unnest(ARRAY['USAGE', 'SELECT', 'UPDATE']) AS p(priv)
              WHERE c.relkind = 'S' AND n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
                AND has_sequence_privilege('ana_exec', c.oid, p.priv) LOOP
        EXECUTE format('GRANT %s ON SEQUENCE %I.%I TO ana_scoped', r.priv, r.nspname, r.relname); n := n + 1;
    END LOOP;
    FOR r IN SELECT table_schema, table_name, column_name, privilege_type FROM information_schema.column_privileges
              WHERE grantee = 'ana_exec'
                AND NOT has_table_privilege('ana_exec', format('%I.%I', table_schema, table_name), privilege_type) LOOP
        EXECUTE format('GRANT %s (%I) ON TABLE %I.%I TO ana_scoped', r.privilege_type, r.column_name, r.table_schema, r.table_name);
        n := n + 1;
    END LOOP;
    FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname NOT IN ('information_schema', 'citus', 'citus_internal', 'columnar', 'columnar_internal')
                AND p.prokind IN ('f', 'p') AND has_function_privilege('ana_exec', p.oid, 'EXECUTE')
                AND NOT has_function_privilege('public', p.oid, 'EXECUTE') LOOP
        EXECUTE format('GRANT EXECUTE ON ROUTINE %s TO ana_scoped', r.sig); n := n + 1;
    END LOOP;
    RETURN n;
END $$;

CREATE FUNCTION pg_temp.scoped(p_table regclass, p_using text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', p_table);
    EXECUTE format('CREATE POLICY all_rows ON %s USING (true)', p_table);
    EXECUTE format('CREATE POLICY data_scope ON %s AS RESTRICTIVE TO ana_scoped USING (%s)', p_table, p_using);
END $$;

SELECT pg_temp.scoped('base.party',
    $q$NOT base.scope_portfolio() OR kind = 'supplier' OR salesperson = current_setting('ana.username', true)$q$);
SELECT pg_temp.scoped('sales.sales_order',
    $q$base.scope_cc(cost_center) AND (NOT base.scope_portfolio() OR salesperson = current_setting('ana.username', true))$q$);
SELECT pg_temp.scoped('finance.bill',      -- the customer's own policy decides (portfolio)
    $q$NOT base.scope_portfolio() OR kind <> 'receivable' OR EXISTS (SELECT 1 FROM base.party p WHERE p.id = party_id)$q$);
SELECT pg_temp.scoped('projects.project',
    $q$base.scope_cc(cost_center) AND (NOT base.scope_projects() OR manager = current_setting('ana.username', true)
       OR EXISTS (SELECT 1 FROM projects.project_member m JOIN projects.employee e ON e.id = m.employee_id
                   WHERE m.project_id = project.id AND e.username = current_setting('ana.username', true)))$q$);
SELECT pg_temp.scoped('production.work_order', 'base.scope_cc(cost_center)');
SELECT pg_temp.scoped('supply.purchase_request', 'base.scope_cc(cost_center)');

GRANT EXECUTE ON FUNCTION base.scope_cc(text), base.scope_portfolio(), base.scope_projects() TO ana_exec, ana_read;

-- The hierarchy of centers is part of each user's scope: changing it refreshes the cached scopes.
CREATE FUNCTION finance.cost_center_scope_changed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('ana_access', '');
    RETURN NULL;
END $$;
CREATE TRIGGER cost_center_scope_changed AFTER INSERT OR UPDATE OR DELETE ON finance.cost_center
    FOR EACH STATEMENT EXECUTE FUNCTION finance.cost_center_scope_changed();

SELECT ana_system.sync_scoped_role();
