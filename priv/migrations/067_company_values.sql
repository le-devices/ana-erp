-- 067 — Company values (spec 065, phase 1): small named business values, typed, with validity and an owner, that
-- any routine reads by name and the company keeps on screen — never written in code. Kept by the core
-- (ana_system); programs read them through ana.value() and the base.company_value* functions below.

-- The catalogs a value may point to (D1), as data: a company adds its own. key_column is compared as text.
CREATE TABLE ana_system.value_reference_kind (
    kind         text PRIMARY KEY CHECK (kind ~ '^[a-z][a-z0-9_]*$'),
    label        text NOT NULL CHECK (length(btrim(label)) BETWEEN 2 AND 60),
    table_name   text NOT NULL CHECK (table_name ~ '^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$'),
    key_column   text NOT NULL CHECK (key_column ~ '^[a-z_][a-z0-9_]*$'),
    label_column text NOT NULL CHECK (label_column ~ '^[a-z_][a-z0-9_]*$')
);
COMMENT ON TABLE ana_system.value_reference_kind IS 'Cadastros que um valor da empresa pode apontar (spec 065)';
INSERT INTO ana_system.value_reference_kind (kind, label, table_name, key_column, label_column) VALUES
    ('cost_center', 'Centro de custo',  'finance.cost_center', 'code',  'name'),
    ('warehouse',   'Depósito',         'inventory.warehouse', 'code',  'description'),
    ('party',       'Parceiro',         'base.party',          'id',    'name'),
    ('account',     'Conta contábil',   'finance.account',     'code',  'description'),
    ('product',     'Produto',          'base.product',        'code',  'description'),
    ('company',     'Empresa ou filial', 'base.company',       'id',    'legal_name');

-- The definition (D1). The area owns it (permission, D9); by default the first part of the name.
CREATE TABLE ana_system.company_value (
    name            text PRIMARY KEY CHECK (name ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,3}$' AND length(name) <= 100),
    description     text NOT NULL CHECK (length(btrim(description)) BETWEEN 3 AND 300),
    area            text NOT NULL CHECK (area ~ '^[a-z][a-z0-9_]*$'),
    value_type      text NOT NULL CHECK (value_type IN ('text', 'integer', 'decimal', 'date', 'boolean', 'month', 'reference')),
    shape           text NOT NULL DEFAULT 'single' CHECK (shape IN ('single', 'list', 'selection')),
    ref_kind        text REFERENCES ana_system.value_reference_kind(kind),
    sensitive       boolean NOT NULL DEFAULT false,              -- a change waits for a second person (four eyes)
    reason_required boolean NOT NULL DEFAULT false,
    same_everywhere boolean NOT NULL DEFAULT false,              -- the content travels in transports (spec 034, phase 2)
    archived        boolean NOT NULL DEFAULT false,
    created_by      text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK ((value_type = 'reference') = (ref_kind IS NOT NULL)),
    CHECK (shape <> 'selection' OR value_type IN ('text', 'integer', 'reference'))
);
COMMENT ON TABLE ana_system.company_value IS 'Valores da empresa: definição (spec 065)';

-- The content, in versions with a start date (D2), optionally for one instance and/or one company of the group (D3).
-- A fixed content (typed JSON) or an expression of the closed list (D5). History is never deleted.
CREATE TABLE ana_system.company_value_version (
    id            bigserial PRIMARY KEY,
    name          text NOT NULL REFERENCES ana_system.company_value(name),
    valid_from    date NOT NULL,
    instance      text CHECK (instance IN ('development', 'test', 'production')),
    company_id    integer REFERENCES base.company(id),
    content       jsonb,
    expression    text CHECK (expression ~ '^[a-z_]+([+-][0-9]{1,4})?$'),
    status        text NOT NULL DEFAULT 'active'
                  CHECK (status IN ('pending', 'active', 'refused', 'withdrawn', 'replaced')),
    reason        text CHECK (length(reason) <= 500),
    requested_by  text NOT NULL,
    requested_at  timestamptz NOT NULL DEFAULT now(),
    decided_by    text,
    decided_at    timestamptz,
    decision_note text CHECK (length(decision_note) <= 500),
    CHECK ((content IS NULL) <> (expression IS NULL)),
    CHECK (decided_by IS NULL OR decided_by <> requested_by)          -- four eyes, enforced by the database
);
CREATE UNIQUE INDEX company_value_version_active_uk ON ana_system.company_value_version
    (name, valid_from, coalesce(instance, ''), coalesce(company_id, 0)) WHERE status = 'active';
CREATE UNIQUE INDEX company_value_version_pending_uk ON ana_system.company_value_version
    (name, valid_from, coalesce(instance, ''), coalesce(company_id, 0)) WHERE status = 'pending';
CREATE INDEX company_value_version_name_idx ON ana_system.company_value_version (name, valid_from DESC);
COMMENT ON TABLE ana_system.company_value_version IS 'Valores da empresa: versões com vigência, instância e empresa (spec 065)';

-- Every change, with before and after (D9, spec 024).
CREATE TABLE ana_system.company_value_change (
    id         bigserial PRIMARY KEY,
    at         timestamptz NOT NULL DEFAULT now(),
    name       text NOT NULL,
    action     text NOT NULL CHECK (action IN ('defined', 'redefined', 'requested', 'activated', 'approved', 'refused',
                                               'withdrawn', 'archived', 'restored')),
    username   text NOT NULL,
    version_id bigint,
    before     jsonb,
    after      jsonb,
    reason     text
);
CREATE INDEX company_value_change_name_idx ON ana_system.company_value_change (name, at DESC);

-- RNF-065-02: the values an execution read stay in its record (with what margin was this approval decided).
ALTER TABLE ana_system.execution ADD COLUMN values_read jsonb;

-- Groups that may change values (D9): value names or "area.*", besides administrators.
ALTER TABLE ana_system.access_group ADD COLUMN value_patterns text[] NOT NULL DEFAULT '{}'
    CHECK (array_position(value_patterns, NULL) IS NULL);

-- Every node reloads the value after COMMIT (D7); the open screens are woken up by the same notice.
CREATE FUNCTION ana_system.company_value_notify() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('ana_value', NEW.name);
    RETURN NULL;
END $$;
CREATE TRIGGER company_value_notify AFTER INSERT OR UPDATE ON ana_system.company_value
    FOR EACH ROW EXECUTE FUNCTION ana_system.company_value_notify();
CREATE TRIGGER company_value_version_notify AFTER INSERT OR UPDATE ON ana_system.company_value_version
    FOR EACH ROW EXECUTE FUNCTION ana_system.company_value_notify();

-- Version in effect (D2, D3): among the active versions started on or before the date, the most specific
-- (instance and company > instance > company > general) and, among those, the most recent.
CREATE FUNCTION ana_system.value_version_at(p_name text, p_at date, p_company int, p_instance text)
RETURNS ana_system.company_value_version LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
    SELECT v.* FROM ana_system.company_value_version v
     WHERE v.name = p_name AND v.status = 'active' AND v.valid_from <= p_at
       AND (v.instance IS NULL OR v.instance = p_instance)
       AND (v.company_id IS NULL OR v.company_id = p_company)
     ORDER BY (v.instance IS NOT NULL) DESC, (v.company_id IS NOT NULL) DESC, v.valid_from DESC
     LIMIT 1
$$;

-- The closed list of dynamic expressions (D5) — the ONLY implementation, shared by values, schedules and (spec 045)
-- variants. The list with labels and the type of the result is value_expressions(), right below.
CREATE FUNCTION ana_system.value_expression(p_expr text, p_at date, p_tz text, p_strict boolean, p_user text)
RETURNS text LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE
    tz  text := coalesce(nullif(p_tz, ''), nullif(current_setting('ana.timezone', true), ''), current_setting('TimeZone'));
    m   text[];
    tok text;
    n   int := 0;
    ts  timestamp;
    d   date;
    r   date;
    v   text;
    pv  ana_system.company_value_version;
BEGIN
    m := regexp_match(coalesce(p_expr, ''), '^([a-z_]+)(?:([+-])([0-9]{1,4}))?$');
    IF m IS NOT NULL THEN
        tok := m[1];
        IF m[2] IS NOT NULL THEN n := CASE m[2] WHEN '-' THEN -m[3]::int ELSE m[3]::int END; END IF;
    END IF;
    IF m IS NULL OR tok NOT IN ('today', 'yesterday', 'tomorrow', 'now', 'month_start', 'month_end', 'last_month_start',
                                'last_month_end', 'next_month_start', 'year_start', 'year_end', 'last_year_start',
                                'last_year_end', 'this_month', 'last_month', 'next_business_day', 'previous_business_day',
                                'open_period', 'current_user', 'user_cost_center')
       OR (m[2] IS NOT NULL AND tok NOT IN ('today', 'open_period')) THEN
        IF NOT p_strict THEN RETURN NULL; END IF;
        RAISE EXCEPTION 'VALUE_EXPRESSION: expressão fora da lista: %', p_expr USING ERRCODE = 'invalid_parameter_value';
    END IF;
    ts := now() AT TIME ZONE tz;
    d := coalesce(p_at, ts::date);
    CASE tok
        WHEN 'today' THEN RETURN (d + n)::text;
        WHEN 'yesterday' THEN RETURN (d - 1)::text;
        WHEN 'tomorrow' THEN RETURN (d + 1)::text;
        WHEN 'now' THEN RETURN to_char(CASE WHEN p_at IS NULL THEN ts ELSE p_at::timestamp END, 'YYYY-MM-DD"T"HH24:MI:SS');
        WHEN 'month_start' THEN RETURN date_trunc('month', d::timestamp)::date::text;
        WHEN 'month_end' THEN RETURN (date_trunc('month', d::timestamp) + interval '1 month' - interval '1 day')::date::text;
        WHEN 'last_month_start' THEN RETURN (date_trunc('month', d::timestamp) - interval '1 month')::date::text;
        WHEN 'last_month_end' THEN RETURN (date_trunc('month', d::timestamp) - interval '1 day')::date::text;
        WHEN 'next_month_start' THEN RETURN (date_trunc('month', d::timestamp) + interval '1 month')::date::text;
        WHEN 'year_start' THEN RETURN date_trunc('year', d::timestamp)::date::text;
        WHEN 'year_end' THEN RETURN (date_trunc('year', d::timestamp) + interval '1 year' - interval '1 day')::date::text;
        WHEN 'last_year_start' THEN RETURN (date_trunc('year', d::timestamp) - interval '1 year')::date::text;
        WHEN 'last_year_end' THEN RETURN (date_trunc('year', d::timestamp) - interval '1 day')::date::text;
        WHEN 'this_month' THEN RETURN to_char(d, 'YYYY-MM');
        WHEN 'last_month' THEN RETURN to_char(d - interval '1 month', 'YYYY-MM');
        WHEN 'next_business_day', 'previous_business_day' THEN
            r := d;
            LOOP
                r := r + CASE tok WHEN 'next_business_day' THEN 1 ELSE -1 END;
                EXIT WHEN extract(isodow FROM r) <= 5 AND NOT EXISTS (SELECT 1 FROM scheduler.holiday h WHERE h.day = r);
            END LOOP;
            RETURN r::text;
        WHEN 'open_period' THEN
            SELECT * INTO pv FROM ana_system.value_version_at('financeiro.periodo_aberto', d, NULL,
                                                             nullif(current_setting('ana.instance', true), ''));
            IF pv.expression LIKE 'open_period%' THEN
                RAISE EXCEPTION 'VALUE_EXPRESSION: o período aberto não pode ser definido por ele mesmo'
                    USING ERRCODE = 'invalid_parameter_value';
            END IF;
            v := CASE WHEN pv.expression IS NOT NULL THEN ana_system.value_expression(pv.expression, p_at, tz, true, p_user)
                      ELSE pv.content #>> '{}' END;
            IF v IS NULL THEN
                RAISE EXCEPTION 'VALUE_NOT_FOUND: o período aberto (financeiro.periodo_aberto) não tem valor em %', d
                    USING ERRCODE = 'no_data_found';
            END IF;
            RETURN to_char(to_date(v || '-01', 'YYYY-MM-DD') + make_interval(months => n), 'YYYY-MM');
        WHEN 'current_user' THEN RETURN coalesce(p_user, nullif(current_setting('ana.username', true), ''));
        WHEN 'user_cost_center' THEN
            -- The first center of the user's restricted groups; otherwise the company's default (spec 027).
            SELECT c INTO v FROM ana_system.user_group ug JOIN ana_system.access_group g ON g.name = ug.group_name,
                                 unnest(g.data_cost_centers) c
             WHERE ug.username = coalesce(p_user, nullif(current_setting('ana.username', true), ''))
             ORDER BY g.name, c LIMIT 1;
            RETURN coalesce(v, (SELECT cost_center FROM finance.default_cost_center WHERE key = 'company'));
    END CASE;
END $$;

CREATE FUNCTION base.value_expressions()
RETURNS TABLE (token text, label text, result_type text, offset_unit text) LANGUAGE sql IMMUTABLE AS $$
    VALUES ('today', 'Hoje (± N dias)', 'date', 'day'),
           ('yesterday', 'Ontem', 'date', NULL),
           ('tomorrow', 'Amanhã', 'date', NULL),
           ('now', 'Agora (data e hora)', 'datetime', NULL),
           ('month_start', 'Início do mês', 'date', NULL),
           ('month_end', 'Fim do mês', 'date', NULL),
           ('last_month_start', 'Início do mês anterior', 'date', NULL),
           ('last_month_end', 'Fim do mês anterior', 'date', NULL),
           ('next_month_start', 'Início do próximo mês', 'date', NULL),
           ('year_start', 'Início do ano', 'date', NULL),
           ('year_end', 'Fim do ano', 'date', NULL),
           ('last_year_start', 'Início do ano anterior', 'date', NULL),
           ('last_year_end', 'Fim do ano anterior', 'date', NULL),
           ('this_month', 'Mês atual', 'month', NULL),
           ('last_month', 'Mês anterior', 'month', NULL),
           ('next_business_day', 'Próximo dia útil', 'date', NULL),
           ('previous_business_day', 'Dia útil anterior', 'date', NULL),
           ('open_period', 'Período aberto (± N meses)', 'month', 'month'),
           ('current_user', 'Usuário atual', 'text', NULL),
           ('user_cost_center', 'Centro de custo do usuário', 'cost_center', NULL)
$$;

-- For programs: the expression for the user of the execution.
CREATE FUNCTION base.resolve_value_expression(p_expr text, p_at date DEFAULT NULL)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
    SELECT ana_system.value_expression(p_expr, p_at, NULL, true, NULL)
$$;

-- Reading in SQL (D6): only reading, the same resolution as the core's memory. The instance comes from
-- ana.instance, set by the core at the start of every execution's transaction.
CREATE FUNCTION ana_system.value_resolved(p_name text, p_at date, p_company int)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE
    tz text := coalesce(nullif(current_setting('ana.timezone', true), ''), current_setting('TimeZone'));
    v  ana_system.company_value_version;
BEGIN
    v := ana_system.value_version_at(p_name, coalesce(p_at, (now() AT TIME ZONE tz)::date), p_company,
                                     nullif(current_setting('ana.instance', true), ''));
    IF v.id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM ana_system.company_value WHERE name = p_name) THEN
            RAISE EXCEPTION 'VALUE_NOT_FOUND: valor da empresa inexistente: %', p_name USING ERRCODE = 'no_data_found';
        END IF;
        RETURN NULL;
    END IF;
    IF v.expression IS NOT NULL THEN
        RETURN to_jsonb(ana_system.value_expression(v.expression, p_at, tz, true, NULL));
    END IF;
    RETURN v.content;
END $$;

CREATE FUNCTION base.company_value(p_name text, p_at date DEFAULT NULL, p_company int DEFAULT NULL)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
    SELECT ana_system.value_resolved(p_name, p_at, p_company) #>> '{}'
$$;

CREATE FUNCTION base.company_value_list(p_name text, p_at date DEFAULT NULL, p_company int DEFAULT NULL)
RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
    SELECT CASE jsonb_typeof(j) WHEN 'array' THEN ARRAY(SELECT jsonb_array_elements_text(j))
                                WHEN 'object' THEN ARRAY(SELECT jsonb_array_elements_text(coalesce(j -> 'include', '[]')))
                                ELSE ARRAY[j #>> '{}'] END
      FROM (SELECT ana_system.value_resolved(p_name, p_at, p_company) AS j) s
     WHERE j IS NOT NULL
$$;

-- A selection (D1): {"include": [...], "ranges": [[from, to], ...], "prefixes": [...], "exclude": [...]}. Numbers are
-- compared as numbers, the rest as text (byte order). Nothing to include = everything but the excluded.
CREATE FUNCTION ana_system.value_selection_matches(p_sel jsonb, p_candidate text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog AS $$
DECLARE
    num constant text := '^-?[0-9]+(\.[0-9]+)?$';
    inc boolean;
    r   jsonb;
BEGIN
    IF p_candidate IS NULL OR p_sel IS NULL THEN RETURN false; END IF;
    IF jsonb_typeof(p_sel) = 'array' THEN RETURN p_sel ? p_candidate OR p_sel @> to_jsonb(p_candidate)
                                                OR (p_candidate ~ num AND p_sel @> jsonb_build_array(p_candidate::numeric)); END IF;
    IF jsonb_typeof(p_sel) <> 'object' THEN RETURN (p_sel #>> '{}') = p_candidate; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(p_sel -> 'exclude', '[]')) x WHERE x = p_candidate) THEN
        RETURN false;
    END IF;
    IF coalesce(jsonb_array_length(p_sel -> 'include'), 0) + coalesce(jsonb_array_length(p_sel -> 'ranges'), 0)
       + coalesce(jsonb_array_length(p_sel -> 'prefixes'), 0) = 0 THEN
        RETURN true;
    END IF;
    inc := EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(p_sel -> 'include', '[]')) x WHERE x = p_candidate)
        OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(p_sel -> 'prefixes', '[]')) x
                    WHERE left(p_candidate, length(x)) = x);
    IF inc THEN RETURN true; END IF;
    FOR r IN SELECT * FROM jsonb_array_elements(coalesce(p_sel -> 'ranges', '[]')) LOOP
        IF (r ->> 0) ~ num AND (r ->> 1) ~ num AND p_candidate ~ num THEN
            IF p_candidate::numeric BETWEEN (r ->> 0)::numeric AND (r ->> 1)::numeric THEN RETURN true; END IF;
        ELSIF (p_candidate COLLATE "C") >= (r ->> 0) AND (p_candidate COLLATE "C") <= (r ->> 1) THEN
            RETURN true;
        END IF;
    END LOOP;
    RETURN false;
END $$;

CREATE FUNCTION base.company_value_matches(p_name text, p_candidate text, p_at date DEFAULT NULL, p_company int DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
    SELECT ana_system.value_selection_matches(ana_system.value_resolved(p_name, p_at, p_company), p_candidate)
$$;

GRANT EXECUTE ON FUNCTION base.value_expressions(), base.resolve_value_expression(text, date),
    base.company_value(text, date, int), base.company_value_list(text, date, int),
    base.company_value_matches(text, text, date, int) TO ana_exec, ana_read;

-- The record a reference points to: its label, or NULL when it does not exist (validation, D1).
CREATE FUNCTION ana_system.value_reference_label(p_kind text, p_key text)
RETURNS text LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE
    k ana_system.value_reference_kind;
    l text;
BEGIN
    SELECT * INTO k FROM ana_system.value_reference_kind WHERE kind = p_kind;
    IF NOT FOUND THEN RETURN NULL; END IF;
    EXECUTE format('SELECT %I::text FROM %s WHERE %I::text = $1 LIMIT 1', k.label_column, k.table_name::regclass, k.key_column)
       INTO l USING p_key;
    RETURN l;
END $$;

-- A record pointed to by a version in effect or still to come cannot be deleted or have its key changed (D1,
-- CA-065-03). Generic: TG_ARGV = (kind, key column).
CREATE FUNCTION ana_system.company_value_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE
    k     text := to_jsonb(OLD) ->> TG_ARGV[1];
    names text;
BEGIN
    IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) ->> TG_ARGV[1]) IS NOT DISTINCT FROM k THEN RETURN NEW; END IF;
    SELECT string_agg(DISTINCT v.name, ', ' ORDER BY v.name) INTO names
      FROM ana_system.company_value_version v JOIN ana_system.company_value d ON d.name = v.name
     WHERE d.ref_kind = TG_ARGV[0] AND v.status IN ('active', 'pending') AND v.content IS NOT NULL
       AND jsonb_path_exists(v.content, '$.** ? (@ == $k)', jsonb_build_object('k', k))
       AND NOT EXISTS (SELECT 1 FROM ana_system.company_value_version w
                        WHERE w.name = v.name AND w.status = 'active' AND w.valid_from > v.valid_from
                          AND w.valid_from <= current_date
                          AND w.instance IS NOT DISTINCT FROM v.instance AND w.company_id IS NOT DISTINCT FROM v.company_id);
    IF names IS NOT NULL THEN
        RAISE EXCEPTION 'VALUE_IN_USE: % é usado pelos valores da empresa: %', k, names
            USING ERRCODE = 'foreign_key_violation', HINT = 'Mude esses valores em Administração → Valores da empresa.';
    END IF;
    RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END $$;

DO $$
DECLARE k record;
BEGIN
    FOR k IN SELECT * FROM ana_system.value_reference_kind LOOP
        EXECUTE format('CREATE TRIGGER company_value_guard BEFORE DELETE OR UPDATE OF %I ON %s FOR EACH ROW '
                       'EXECUTE FUNCTION ana_system.company_value_guard(%L, %L)',
                       k.key_column, k.table_name::regclass, k.kind, k.key_column);
    END LOOP;
END $$;

-- The open period (spec 055 will move it at each closing); until then, the current month.
INSERT INTO ana_system.company_value (name, description, area, value_type, created_by)
VALUES ('financeiro.periodo_aberto', 'Período contábil aberto para lançamentos', 'financeiro', 'month', 'ana');
INSERT INTO ana_system.company_value_version (name, valid_from, expression, requested_by)
VALUES ('financeiro.periodo_aberto', DATE '2000-01-01', 'this_month', 'ana');
