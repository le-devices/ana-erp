-- 038 — Master data, standardized (spec 040): validators in the database, field-level history by a
-- generic trigger, change requests for sensitive fields, custom fields, fast search.

-- ---------------------------------------------------------------- validators (RNF-040-02, CA-040-02)
CREATE FUNCTION base.only_digits(p text) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT regexp_replace(COALESCE(p, ''), '[^0-9]', '', 'g')
$$;

CREATE FUNCTION base.valid_cpf(p text) RETURNS boolean LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE d text := base.only_digits(p); s int; r int; i int;
BEGIN
    IF length(d) <> 11 OR d ~ '^(\d)\1{10}$' THEN RETURN false; END IF;
    s := 0; FOR i IN 1..9 LOOP s := s + substr(d, i, 1)::int * (11 - i); END LOOP;
    r := (s * 10) % 11; IF r = 10 THEN r := 0; END IF;
    IF r <> substr(d, 10, 1)::int THEN RETURN false; END IF;
    s := 0; FOR i IN 1..10 LOOP s := s + substr(d, i, 1)::int * (12 - i); END LOOP;
    r := (s * 10) % 11; IF r = 10 THEN r := 0; END IF;
    RETURN r = substr(d, 11, 1)::int;
END $$;

CREATE FUNCTION base.valid_cnpj(p text) RETURNS boolean LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE d text := base.only_digits(p); w int[] := ARRAY[6,5,4,3,2,9,8,7,6,5,4,3,2]; s int; r int; i int;
BEGIN
    IF length(d) <> 14 OR d ~ '^(\d)\1{13}$' THEN RETURN false; END IF;
    s := 0; FOR i IN 1..12 LOOP s := s + substr(d, i, 1)::int * w[i + 1]; END LOOP;
    r := s % 11; r := CASE WHEN r < 2 THEN 0 ELSE 11 - r END;
    IF r <> substr(d, 13, 1)::int THEN RETURN false; END IF;
    s := 0; FOR i IN 1..13 LOOP s := s + substr(d, i, 1)::int * w[i]; END LOOP;
    r := s % 11; r := CASE WHEN r < 2 THEN 0 ELSE 11 - r END;
    RETURN r = substr(d, 14, 1)::int;
END $$;

CREATE FUNCTION base.valid_tax_id(p text) RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT p IS NULL OR btrim(p) = '' OR base.valid_cpf(p) OR base.valid_cnpj(p)
$$;

CREATE FUNCTION base.format_tax_id(p text) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE length(base.only_digits(p))
        WHEN 11 THEN regexp_replace(base.only_digits(p), '^(\d{3})(\d{3})(\d{3})(\d{2})$', '\1.\2.\3-\4')
        WHEN 14 THEN regexp_replace(base.only_digits(p), '^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$', '\1.\2.\3/\4-\5')
        ELSE NULLIF(btrim(p), '') END
$$;

-- Accent-insensitive, case-insensitive text for search and duplicates (no extension needed).
CREATE FUNCTION base.norm(p text) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT lower(translate(COALESCE(p, ''),
        'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ',
        'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn'))
$$;

-- The document is checked and formatted whenever it changes, from any path; old rows stay editable.
CREATE FUNCTION base.party_tax_id() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.tax_id IS DISTINCT FROM OLD.tax_id THEN
        NEW.tax_id := NULLIF(btrim(NEW.tax_id), '');
        IF NEW.tax_id IS NOT NULL THEN
            IF NOT base.valid_tax_id(NEW.tax_id) THEN
                RAISE EXCEPTION 'INVALID_TAX_ID: CNPJ/CPF % inválido: confira os números (dígito verificador)', NEW.tax_id
                    USING ERRCODE = 'check_violation';
            END IF;
            NEW.tax_id := base.format_tax_id(NEW.tax_id);
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER party_tax_id BEFORE INSERT OR UPDATE OF tax_id ON base.party
    FOR EACH ROW EXECUTE FUNCTION base.party_tax_id();

-- ---------------------------------------------------------------- shape of the master tables (RF-040-01, 05)
ALTER TABLE inventory.warehouse ADD COLUMN active boolean NOT NULL DEFAULT true;
ALTER TABLE base.party ADD COLUMN custom jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(custom) = 'object');
ALTER TABLE base.product ADD COLUMN custom jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(custom) = 'object');

CREATE INDEX party_search_trgm ON base.party USING gin (base.norm(name) public.gin_trgm_ops);
CREATE INDEX product_search_trgm ON base.product USING gin (base.norm(code || ' ' || description) public.gin_trgm_ops);
CREATE INDEX party_email_idx ON base.party (lower(email)) WHERE email IS NOT NULL;

CREATE SCHEMA master;

-- Client's own fields (data, not schema): validated by the service, stored in the `custom` column.
CREATE TABLE master.custom_field (
    entity     text NOT NULL CHECK (entity IN ('party', 'product')),
    name       text NOT NULL CHECK (name ~ '^[a-z][a-z0-9_]{1,40}$'),
    label      text NOT NULL CHECK (length(label) BETWEEN 2 AND 80),
    type       text NOT NULL CHECK (type IN ('text', 'int', 'decimal', 'bool', 'date', 'choice')),
    required   boolean NOT NULL DEFAULT false,
    choices    text[] NOT NULL DEFAULT '{}',
    position   integer NOT NULL DEFAULT 0,
    active     boolean NOT NULL DEFAULT true,
    created_by text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (entity, name)
);

-- ---------------------------------------------------------------- field-level history (RF-040-06)
CREATE TABLE master.change_log (
    id           bigserial PRIMARY KEY,
    at           timestamptz NOT NULL DEFAULT now(),
    entity       text NOT NULL,
    row_key      text NOT NULL,
    table_name   text NOT NULL,
    op           text NOT NULL CHECK (op IN ('insert', 'update', 'delete', 'merge', 'request', 'approve', 'reject', 'note')),
    changes      jsonb NOT NULL,
    username     text,
    origin       text,
    execution_id text
);
CREATE INDEX change_log_at_brin ON master.change_log USING brin (at);
CREATE INDEX change_log_row_idx ON master.change_log (entity, row_key, id DESC);

-- TG_ARGV: entity, column that identifies the master row, secret columns (comma separated).
CREATE FUNCTION master.log_changes() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    o jsonb := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
    n jsonb := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) ELSE '{}'::jsonb END;
    secret text[] := string_to_array(COALESCE(NULLIF(TG_ARGV[2], ''), ''), ',');
    diff jsonb := '{}'::jsonb;
    k text;
BEGIN
    FOR k IN SELECT jsonb_object_keys(o || n) LOOP
        CONTINUE WHEN k IN ('created_at', 'updated_at', 'updated_by', 'created_by');
        IF (o -> k) IS DISTINCT FROM (n -> k) THEN
            diff := diff || jsonb_build_object(k, CASE WHEN k = ANY(secret) THEN '["***", "***"]'::jsonb
                                                       ELSE jsonb_build_array(o -> k, n -> k) END);
        END IF;
    END LOOP;
    IF diff <> '{}'::jsonb THEN
        INSERT INTO master.change_log (entity, row_key, table_name, op, changes, username, origin, execution_id)
        VALUES (TG_ARGV[0], COALESCE(n ->> TG_ARGV[1], o ->> TG_ARGV[1]), TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
                lower(TG_OP), diff, NULLIF(current_setting('ana.username', true), ''),
                NULLIF(current_setting('ana.origin', true), ''), NULLIF(current_setting('ana.execution_id', true), ''));
    END IF;
    RETURN NULL;
END $$;

DO $$
DECLARE t record;
BEGIN
    FOR t IN SELECT * FROM (VALUES
        ('base.party', 'party', 'id', ''),
        ('finance.credit_profile', 'party', 'party_id', ''),
        ('base.product', 'product', 'id', ''),
        ('production.item_plan', 'product', 'product_id', ''),
        ('supply.supplier_item', 'product', 'product_id', ''),
        ('supply.replenishment_rule', 'product', 'product_id', ''),
        ('inventory.warehouse', 'warehouse', 'id', ''),
        ('finance.cost_center', 'cost_center', 'code', ''),
        ('finance.bank_account', 'bank_account', 'code', ''),
        ('finance.payment_term', 'payment_term', 'code', ''),
        ('logistics.carrier', 'carrier', 'id', ''),
        ('logistics.freight_rate', 'carrier', 'carrier_id', ''),
        ('projects.employee', 'employee', 'id', 'hourly_cost'),
        ('projects.rate_profile', 'profile', 'code', ''),
        ('field.technician', 'technician', 'employee_id', ''),
        ('production.resource', 'resource', 'code', '')) AS x(tbl, entity, keycol, secret) LOOP
        EXECUTE format('CREATE TRIGGER master_log AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW '
                       'EXECUTE FUNCTION master.log_changes(%L, %L, %L)', t.tbl, t.entity, t.keycol, t.secret);
    END LOOP;
END $$;

-- ---------------------------------------------------------------- change requests (RF-040-08)
CREATE TABLE master.change_request (
    id           bigserial PRIMARY KEY,
    entity       text NOT NULL,
    row_key      text,
    title        text NOT NULL,
    changes      jsonb NOT NULL CHECK (jsonb_typeof(changes) = 'object'),
    status       text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'applied', 'rejected', 'cancelled')),
    requested_by text NOT NULL,
    requested_at timestamptz NOT NULL DEFAULT now(),
    decided_by   text,
    decided_at   timestamptz,
    reason       text,
    CHECK (decided_by IS NULL OR decided_by <> requested_by)          -- four eyes
);
CREATE INDEX change_request_pending_idx ON master.change_request (entity, row_key) WHERE status = 'pending';

-- Approval of sensitive fields, per entity (off by default: the owner decides, P13).
CREATE TABLE master.policy (
    entity   text PRIMARY KEY,
    approval boolean NOT NULL DEFAULT false,
    updated_by text,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- How many rows reference a master record (merge and delete need it, also for tables the executions
-- cannot read, e.g. portal accounts). Counts only; the identifiers must be a real foreign key.
CREATE FUNCTION master.reference_count(p_table text, p_column text, p_value text) RETURNS bigint
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE n bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
                   WHERE c.contype = 'f' AND c.conrelid = p_table::regclass AND a.attname = p_column) THEN
        RAISE EXCEPTION 'not a foreign key: %.%', p_table, p_column;
    END IF;
    EXECUTE format('SELECT count(*) FROM %s WHERE %I::text = $1', p_table::regclass, p_column) INTO n USING p_value;
    RETURN n;
END $$;

-- ---------------------------------------------------------------- grants
GRANT USAGE ON SCHEMA master TO ana_exec, ana_read;
GRANT SELECT ON ALL TABLES IN SCHEMA master TO ana_exec, ana_read;
GRANT INSERT, UPDATE, DELETE ON master.custom_field, master.policy TO ana_exec;
GRANT INSERT, UPDATE ON master.change_request TO ana_exec;
GRANT INSERT ON master.change_log TO ana_exec;
GRANT USAGE ON SEQUENCE master.change_request_id_seq, master.change_log_id_seq TO ana_exec;
GRANT EXECUTE ON FUNCTION base.only_digits(text), base.valid_cpf(text), base.valid_cnpj(text), base.valid_tax_id(text),
    base.format_tax_id(text), base.norm(text) TO ana_exec, ana_read;
REVOKE ALL ON FUNCTION master.log_changes() FROM PUBLIC;
REVOKE ALL ON FUNCTION master.reference_count(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION master.reference_count(text, text, text) TO ana_exec, ana_read;
