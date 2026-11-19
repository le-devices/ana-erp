-- 064 — Tax engine (spec 049, phase 1; D10 Simples; D11/P21 legislation is data).
-- Generic structures only: taxes, attributes, codes, tables, indicators and rules are rows. A change in the
-- law (including the 2026–2033 transition) is a rule package, never a new migration.

CREATE SCHEMA tax;

-- Taxes: free codes; accounting by role (expense, payable, withheld, credit, credit_offset) → default account key or code.
CREATE TABLE tax.tax (
    code       text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{0,39}$'),
    name       text NOT NULL CHECK (length(name) BETWEEN 2 AND 120),
    sequence   integer NOT NULL DEFAULT 100,
    scope      text NOT NULL DEFAULT 'item' CHECK (scope IN ('item', 'document')),
    roles      jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(roles) = 'object'),
    active     boolean NOT NULL DEFAULT true,
    package    text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by text NOT NULL DEFAULT 'system'
);
COMMENT ON TABLE tax.tax IS 'Tributos (cadastro): ordem de cálculo, escopo e contas por papel';

-- Fiscal attributes of company, people, items and contracts (D11): definitions + values with validity.
CREATE TABLE tax.attribute (
    entity      text NOT NULL CHECK (entity IN ('company', 'party', 'item', 'contract')),
    code        text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]{0,39}$'),
    value_type  text NOT NULL DEFAULT 'text' CHECK (value_type IN ('text', 'number', 'boolean', 'date')),
    code_list   text,
    source      text CHECK (source ~ '^[a-z][a-z0-9_]{0,62}$'),
    description text NOT NULL DEFAULT '',
    package     text,
    PRIMARY KEY (entity, code)
);
COMMENT ON TABLE tax.attribute IS 'Atributos fiscais (definição); fonte = coluna do cadastro já existente';

CREATE TABLE tax.attribute_value (
    id          bigserial PRIMARY KEY,
    entity      text NOT NULL,
    entity_id   text NOT NULL CHECK (length(entity_id) BETWEEN 1 AND 60),
    attribute   text NOT NULL,
    value       text,
    valid_from  date,
    valid_to    date,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  text NOT NULL,
    FOREIGN KEY (entity, attribute) REFERENCES tax.attribute (entity, code) ON UPDATE CASCADE,
    CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from),
    EXCLUDE USING gist (entity WITH =, entity_id WITH =, attribute WITH =,
                        daterange(COALESCE(valid_from, '-infinity'), COALESCE(valid_to, 'infinity'), '[]') WITH &&)
);
COMMENT ON TABLE tax.attribute_value IS 'Valores de atributos fiscais com vigência (sem sobreposição)';

-- Code lists with validity (NCM, NBS, service list, CST, reform classification, regimes…).
CREATE TABLE tax.code (
    list        text NOT NULL CHECK (list ~ '^[a-z][a-z0-9_]{0,39}$'),
    code        text NOT NULL CHECK (length(code) BETWEEN 1 AND 40),
    description text NOT NULL DEFAULT '',
    valid_from  date,
    valid_to    date,
    package     text,
    PRIMARY KEY (list, code)
);

-- Support tables with validity (rates by city, by year, progressive brackets: key "<group>/<order>", value = limit).
CREATE TABLE tax.table_row (
    id          bigserial PRIMARY KEY,
    table_name  text NOT NULL CHECK (table_name ~ '^[a-z][a-z0-9_]{0,39}$'),
    key         text NOT NULL CHECK (length(key) BETWEEN 1 AND 120),
    valid_from  date,
    valid_to    date,
    value       numeric(20,8),
    data        jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(data) = 'object'),
    package     text,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  text NOT NULL DEFAULT 'system',
    CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from),
    EXCLUDE USING gist (table_name WITH =, key WITH =,
                        daterange(COALESCE(valid_from, '-infinity'), COALESCE(valid_to, 'infinity'), '[]') WITH &&)
);
CREATE INDEX table_row_name_idx ON tax.table_row (table_name, key);
COMMENT ON TABLE tax.table_row IS 'Tabelas de apoio com vigência (alíquotas, faixas, códigos)';

-- Indicators summed from the books (account_sum) or derived (formula); never typed in.
CREATE TABLE tax.indicator (
    code        text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{0,39}$'),
    kind        text NOT NULL CHECK (kind IN ('account_sum', 'formula')),
    definition  jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
    description text NOT NULL DEFAULT '',
    package     text
);

-- Rules with validity. An active rule never changes: a new date is a copy (RF-049-02).
CREATE TABLE tax.rule (
    id                bigserial PRIMARY KEY,
    tax               text NOT NULL REFERENCES tax.tax(code) ON UPDATE CASCADE,
    name              text NOT NULL CHECK (length(name) BETWEEN 2 AND 200),
    valid_from        date NOT NULL,
    valid_to          date,
    criteria          jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(criteria) = 'object'),
    formulas          jsonb NOT NULL CHECK (jsonb_typeof(formulas) = 'array'),
    exception_program text,
    status            text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'active', 'retired')),
    version           integer NOT NULL DEFAULT 1,
    package           text,
    package_key       text,
    copied_from       bigint REFERENCES tax.rule(id),
    reason            text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        text NOT NULL,
    activated_at      timestamptz,
    activated_by      text,
    CHECK (valid_to IS NULL OR valid_to >= valid_from)
);
CREATE INDEX rule_tax_idx ON tax.rule (tax, status);
CREATE UNIQUE INDEX rule_package_key_uk ON tax.rule (package, package_key, valid_from) WHERE package IS NOT NULL;
COMMENT ON TABLE tax.rule IS 'Regras de cálculo com vigência, critérios e fórmulas';

CREATE FUNCTION tax.rule_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status = 'active' AND (NEW.criteria IS DISTINCT FROM OLD.criteria OR NEW.formulas IS DISTINCT FROM OLD.formulas
        OR NEW.valid_from IS DISTINCT FROM OLD.valid_from OR NEW.tax IS DISTINCT FROM OLD.tax
        OR NEW.status = 'draft') THEN
        RAISE EXCEPTION 'TAX_RULE_ACTIVE: regra % ativa não muda; copie com nova data', OLD.id USING ERRCODE = 'P0001';
    END IF;
    IF OLD.status = 'retired' AND NEW.status <> 'retired' THEN
        RAISE EXCEPTION 'TAX_RULE_RETIRED: regra % retirada', OLD.id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.criteria IS DISTINCT FROM OLD.criteria OR NEW.formulas IS DISTINCT FROM OLD.formulas THEN
        NEW.version := OLD.version + 1;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER rule_guard BEFORE UPDATE ON tax.rule FOR EACH ROW EXECUTE FUNCTION tax.rule_guard();
CREATE FUNCTION tax.rule_no_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status <> 'draft' THEN
        RAISE EXCEPTION 'TAX_RULE_KEEP: regra % já usada não é apagada; retire-a', OLD.id USING ERRCODE = 'P0001';
    END IF;
    RETURN OLD;
END $$;
CREATE TRIGGER rule_no_delete BEFORE DELETE ON tax.rule FOR EACH ROW EXECUTE FUNCTION tax.rule_no_delete();

-- Company test cases (D6).
CREATE TABLE tax.test_case (
    id          bigserial PRIMARY KEY,
    name        text NOT NULL CHECK (length(name) BETWEEN 2 AND 200),
    document    jsonb NOT NULL CHECK (jsonb_typeof(document) = 'object'),
    expected    jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(expected) = 'object'),
    package     text,
    package_key text,
    active      boolean NOT NULL DEFAULT true,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  text NOT NULL
);
CREATE UNIQUE INDEX test_case_package_uk ON tax.test_case (package, package_key) WHERE package IS NOT NULL;

-- Every calculation stored with its document (RF-049-11): input, rules and versions, result.
CREATE TABLE tax.calculation (
    id         bigserial PRIMARY KEY,
    doc_kind   text NOT NULL CHECK (length(doc_kind) BETWEEN 1 AND 40),
    doc_ref    text NOT NULL CHECK (length(doc_ref) BETWEEN 1 AND 60),
    fact_date  date NOT NULL,
    input      jsonb NOT NULL,
    rules      jsonb NOT NULL,
    result     jsonb NOT NULL,
    hash       text NOT NULL CHECK (hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by text NOT NULL
);
CREATE INDEX calculation_doc_idx ON tax.calculation (doc_kind, doc_ref);
CREATE INDEX calculation_created_brin ON tax.calculation USING brin (created_at);

-- Activations and package applications (RNF-049-03): author, reason, cases run and differences accepted.
CREATE TABLE tax.change (
    id          bigserial PRIMARY KEY,
    kind        text NOT NULL CHECK (kind IN ('activate', 'retire', 'package', 'copy')),
    target      text NOT NULL,
    reason      text NOT NULL CHECK (length(reason) BETWEEN 3 AND 1000),
    cases_run   integer NOT NULL DEFAULT 0,
    differences jsonb NOT NULL DEFAULT '[]',
    at          timestamptz NOT NULL DEFAULT now(),
    username    text NOT NULL
);
CREATE INDEX change_at_brin ON tax.change USING brin (at);

CREATE TABLE tax.package (
    name       text PRIMARY KEY,
    version    text NOT NULL,
    hash       text NOT NULL CHECK (hash ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT now(),
    applied_by text NOT NULL
);

-- Version of rules and tables: the engine cache is invalidated when it changes (RNF-049-01).
CREATE TABLE tax.state (
    id      boolean PRIMARY KEY DEFAULT true CHECK (id),
    version bigint NOT NULL DEFAULT 1
);
INSERT INTO tax.state DEFAULT VALUES;
CREATE FUNCTION tax.bump() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
    UPDATE tax.state SET version = version + 1;
    RETURN NULL;
END $$;
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['tax', 'attribute', 'attribute_value', 'code', 'table_row', 'indicator', 'rule'] LOOP
        EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON tax.%I FOR EACH STATEMENT EXECUTE FUNCTION tax.bump()',
                       t || '_bump', t);
    END LOOP;
END $$;

-- Start of activity: the indicators of the first year annualize the months already lived (D10).
ALTER TABLE base.company ADD COLUMN activity_start date;

-- Accounts by role, in the product's chart (customers adjust them in Contas padrão).
INSERT INTO finance.account (code, description, nature, postable, cost_center_policy) VALUES
    ('1.1.9', 'Tributos retidos a compensar', 'asset', true, 'none'),
    ('1.1.10', 'Tributos a recuperar', 'asset', true, 'none'),
    ('2.1.4', 'Simples Nacional a recolher', 'liability', true, 'none'),
    ('2.1.5', 'ISS a recolher', 'liability', true, 'none'),
    ('2.1.6', 'Tributos federais a recolher', 'liability', true, 'none'),
    ('2.1.7', 'Tributos sobre a receita a recolher', 'liability', true, 'none'),
    ('4.9', 'Deduções da receita', 'revenue', false, 'none'),
    ('4.9.1', 'Tributos sobre a receita', 'revenue', true, 'optional'),
    ('5.5', 'Pessoal', 'expense', false, 'none'),
    ('5.5.1', 'Salários e encargos', 'expense', true, 'optional'),
    ('5.5.2', 'Pró-labore', 'expense', true, 'optional')
ON CONFLICT DO NOTHING;
INSERT INTO finance.default_account (key, account, description) VALUES
    ('tax_on_revenue', '4.9.1', 'Tributos sobre a receita (dedução)'),
    ('simples_payable', '2.1.4', 'Simples Nacional a recolher'),
    ('iss_payable', '2.1.5', 'ISS a recolher'),
    ('federal_payable', '2.1.6', 'Tributos federais a recolher'),
    ('revenue_tax_payable', '2.1.7', 'Tributos sobre a receita a recolher'),
    ('federal_withheld', '1.1.9', 'Tributos federais retidos pelo cliente, a compensar'),
    ('tax_recoverable', '1.1.10', 'Tributos a recuperar (créditos)'),
    ('payroll', '5.5.1', 'Salários e encargos'),
    ('owner_compensation', '5.5.2', 'Pró-labore')
ON CONFLICT DO NOTHING;

-- The project invoice keeps the link to its calculation.
ALTER TABLE projects.invoice ADD COLUMN tax_calculation_id bigint REFERENCES tax.calculation(id);
CREATE INDEX invoice_tax_calculation_idx ON projects.invoice (tax_calculation_id);

-- ISS already configured per project becomes data: one rule per project with the same rate and withholding
-- (CA-049-01: "the project invoice gives the same ISS as before"). Withheld ISS settles the ISS payable.
INSERT INTO tax.tax (code, name, sequence, scope, roles, updated_by)
SELECT 'iss', 'ISS', 30, 'item',
       '{"expense": "tax_on_revenue", "payable": "iss_payable", "withheld": "iss_payable"}', 'migration'
WHERE EXISTS (SELECT 1 FROM projects.project WHERE service_tax_rate > 0)
ON CONFLICT DO NOTHING;
INSERT INTO tax.rule (tax, name, valid_from, criteria, formulas, status, created_by, activated_at, activated_by, reason)
SELECT 'iss', 'ISS do projeto ' || p.code || ' (alíquota que estava no projeto)', '2000-01-01',
       jsonb_build_object('contract.code', p.code, 'doc.operation', 'service_sale'),
       jsonb_build_array(jsonb_build_array('base', 'amount'),
                         jsonb_build_array('rate', p.service_tax_rate::text),
                         jsonb_build_array('amount', 'round(base * rate, 2)'))
         || CASE WHEN p.service_tax_withheld THEN jsonb_build_array(jsonb_build_array('withheld', 'amount'))
                 ELSE '[]'::jsonb END,
       'active', 'migration', now(), 'migration', 'migração do ISS configurado no projeto (spec 049)'
FROM projects.project p WHERE p.service_tax_rate > 0;

-- People allowed to change taxes (RNF-049-03), besides administrators.
INSERT INTO ana_system.access_group (name, description, program_patterns)
VALUES ('tax', 'Responsáveis tributários: regras, tabelas, atributos e casos de teste de impostos', ARRAY['tax.*'])
ON CONFLICT DO NOTHING;

-- Programs never read ana_system (P10): two narrow answers instead.
CREATE FUNCTION tax.can_change(p_user text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
    SELECT EXISTS (SELECT 1 FROM ana_system.app_user u WHERE u.username = p_user AND u.active
                    AND (u.role = 'admin' OR EXISTS (SELECT 1 FROM ana_system.user_group g
                                                     WHERE g.username = u.username AND g.group_name = 'tax')))
$$;
CREATE FUNCTION tax.packages() RETURNS TABLE (name text, description text) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
    SELECT substr(p.name, length('tax.package_') + 1), p.description FROM ana_system.program p
     WHERE p.name LIKE 'tax.package\_%' AND p.kind = 'library' ORDER BY p.name
$$;
REVOKE ALL ON FUNCTION tax.can_change(text), tax.packages() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tax.can_change(text), tax.packages() TO ana_exec;

GRANT USAGE ON SCHEMA tax TO ana_exec, ana_read;
GRANT SELECT ON ALL TABLES IN SCHEMA tax TO ana_exec, ana_read;
GRANT INSERT, UPDATE, DELETE ON tax.tax, tax.attribute, tax.attribute_value, tax.code, tax.table_row, tax.indicator,
    tax.rule, tax.test_case, tax.package TO ana_exec;
GRANT INSERT ON tax.calculation, tax.change TO ana_exec;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA tax TO ana_exec;
GRANT UPDATE (tax_calculation_id) ON projects.invoice TO ana_exec;
