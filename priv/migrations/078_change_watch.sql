-- 078 — Change watch (spec 068), part 1: the catalog of what may be watched (T-068-01, D2, D7, D10) and the
-- supplier's bank account (T-068-13), the classic case of a change that must be checked by someone else.
-- No trigger is installed by this migration: watching a document is installed only while a rule needs it (plan.md).

-- ---------------------------------------------------------------- supplier bank account (T-068-13, D10)
CREATE TABLE base.party_bank (
    id         bigserial PRIMARY KEY,
    party_id   integer NOT NULL REFERENCES base.party(id) ON DELETE CASCADE,
    bank       text NOT NULL CHECK (bank ~ '^[0-9]{3}$'),                       -- COMPE code
    branch     text NOT NULL CHECK (branch ~ '^[0-9]{1,5}(-[0-9Xx])?$'),
    account    text NOT NULL CHECK (account ~ '^[0-9]{1,20}(-[0-9Xx])?$'),
    kind       text NOT NULL DEFAULT 'checking' CHECK (kind IN ('checking', 'savings', 'payment')),
    pix_key    text CHECK (length(pix_key) BETWEEN 1 AND 77),
    main       boolean NOT NULL DEFAULT false,
    UNIQUE (party_id, bank, branch, account)
);
CREATE UNIQUE INDEX party_bank_main_uk ON base.party_bank (party_id) WHERE main;
-- History of the party, with the secret columns masked (the value never reaches the history, an event or a notice).
CREATE TRIGGER master_log AFTER INSERT OR UPDATE OR DELETE ON base.party_bank FOR EACH ROW
    EXECUTE FUNCTION master.log_changes('party', 'party_id', 'branch,account,pix_key');
GRANT SELECT, INSERT, UPDATE, DELETE ON base.party_bank TO ana_exec;
GRANT USAGE ON SEQUENCE base.party_bank_id_seq TO ana_exec;
GRANT SELECT ON base.party_bank TO ana_read;

-- ---------------------------------------------------------------- catalog (T-068-01)
-- Entities that may be watched. 'master': its changes are read from master.change_log (no write added, D4);
-- 'document': a check installed on demand writes one event per command (D5). Volume 'high': append-only tables that
-- are never watched by field (D7) — the screen explains it and offers the metric and time triggers.
CREATE TABLE automation.watch_entity (
    entity     text PRIMARY KEY CHECK (entity ~ '^[a-z][a-z0-9_]{1,40}$'),
    label      text NOT NULL CHECK (length(label) BETWEEN 2 AND 80),
    source     text NOT NULL CHECK (source IN ('master', 'document')),
    table_name text NOT NULL CHECK (table_name ~ '^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$'),
    key_column text NOT NULL CHECK (key_column ~ '^[a-z_][a-z0-9_]*$'),   -- for documents: the business key (number)
    id_column  text NOT NULL CHECK (id_column ~ '^[a-z_][a-z0-9_]*$'),    -- the row id that child tables refer to
    volume     text NOT NULL DEFAULT 'normal' CHECK (volume IN ('normal', 'high')),
    alternative text CHECK (length(alternative) <= 300)                  -- what to use instead (volume 'high')
);

-- Fields that may be watched, with the label people see and the classification that decides where the value may go.
-- A field may live in a child table (an order item, a credit profile): via_column names its link to the entity row.
CREATE TABLE automation.watch_field (
    entity         text NOT NULL REFERENCES automation.watch_entity(entity) ON DELETE CASCADE,
    table_name     text NOT NULL CHECK (table_name ~ '^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$'),
    column_name    text NOT NULL CHECK (column_name ~ '^[a-z_][a-z0-9_]*$'),
    via_column     text CHECK (via_column ~ '^[a-z_][a-z0-9_]*$'),
    label          text NOT NULL CHECK (length(label) BETWEEN 2 AND 120),
    type           text NOT NULL CHECK (type IN ('text', 'number', 'money', 'date', 'datetime', 'bool', 'choice', 'ref')),
    classification text NOT NULL DEFAULT 'common' CHECK (classification IN ('common', 'personal', 'secret')),
    PRIMARY KEY (entity, table_name, column_name)
);

-- The database itself refuses what must never be watched (CA-068-08), whoever writes the catalog.
CREATE FUNCTION automation.check_watchable() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    -- Only business schemas: never ana_system (users, sessions, keys, licences), automation (loops), integration
    -- (vault, queues), master (the history itself), bpm, scheduler, files, tax, rehearsal or analytics.
    allowed constant text[] := ARRAY['base', 'finance', 'inventory', 'sales', 'supply', 'production', 'logistics',
                                     'field', 'projects'];
    tbl text := NEW.table_name;
    rel oid;
    e automation.watch_entity;
    col text;
BEGIN
    IF split_part(tbl, '.', 1) <> ALL (allowed) THEN
        RAISE EXCEPTION 'FORBIDDEN: % não pode ser vigiada', tbl USING ERRCODE = 'insufficient_privilege';
    END IF;
    rel := to_regclass(tbl);
    IF rel IS NULL THEN
        RAISE EXCEPTION 'INVALID_PARAMETER: tabela % não existe', tbl USING ERRCODE = 'check_violation';
    END IF;
    IF TG_TABLE_NAME = 'watch_entity' THEN
        FOREACH col IN ARRAY ARRAY[NEW.key_column, NEW.id_column] LOOP
            IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = rel AND attname = col AND attnum > 0 AND NOT attisdropped) THEN
                RAISE EXCEPTION 'INVALID_PARAMETER: coluna %.% não existe', tbl, col USING ERRCODE = 'check_violation';
            END IF;
        END LOOP;
        RETURN NEW;
    END IF;
    SELECT * INTO e FROM automation.watch_entity WHERE entity = NEW.entity;
    IF e.volume = 'high' THEN
        RAISE EXCEPTION 'INVALID_PARAMETER: % tem muito movimento e não é vigiado por campo: %', e.label, e.alternative
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.column_name ~ '(password|secret|token|hash|salt|key_enc)' THEN
        RAISE EXCEPTION 'FORBIDDEN: % não pode ser vigiado', NEW.column_name USING ERRCODE = 'insufficient_privilege';
    END IF;
    FOREACH col IN ARRAY ARRAY[NEW.column_name, COALESCE(NEW.via_column, NEW.column_name)] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = rel AND attname = col AND attnum > 0 AND NOT attisdropped) THEN
            RAISE EXCEPTION 'INVALID_PARAMETER: coluna %.% não existe', tbl, col USING ERRCODE = 'check_violation';
        END IF;
    END LOOP;
    IF e.source = 'master' THEN
        -- A master field is watched through the history: its table must write it, for this entity.
        IF NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = rel AND t.tgname = 'master_log'
                          AND split_part(encode(t.tgargs, 'escape'), '\000', 1) = NEW.entity) THEN
            RAISE EXCEPTION 'INVALID_PARAMETER: % não grava o histórico de %', tbl, NEW.entity USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.via_column IS NOT NULL THEN
            RAISE EXCEPTION 'INVALID_PARAMETER: o histórico já diz a que cadastro a linha pertence' USING ERRCODE = 'check_violation';
        END IF;
    ELSIF (tbl = e.table_name) <> (NEW.via_column IS NULL) THEN
        RAISE EXCEPTION 'INVALID_PARAMETER: campo de outra tabela do documento precisa da coluna de ligação'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER check_watchable BEFORE INSERT OR UPDATE ON automation.watch_entity
    FOR EACH ROW EXECUTE FUNCTION automation.check_watchable();
CREATE TRIGGER check_watchable BEFORE INSERT OR UPDATE ON automation.watch_field
    FOR EACH ROW EXECUTE FUNCTION automation.check_watchable();

-- The company's own fields (master.custom_field) are watchable without anyone listing them; their classification is
-- chosen with the field (spec 040 settings). They live in the "custom" column, recorded in the history as one change.
ALTER TABLE master.custom_field
    ADD COLUMN classification text NOT NULL DEFAULT 'common' CHECK (classification IN ('common', 'personal', 'secret'));

-- ---------------------------------------------------------------- the product's catalog
INSERT INTO automation.watch_entity (entity, label, source, table_name, key_column, id_column, volume, alternative) VALUES
    ('party', 'Cliente ou fornecedor', 'master', 'base.party', 'id', 'id', 'normal', NULL),
    ('product', 'Item', 'master', 'base.product', 'id', 'id', 'normal', NULL),
    ('warehouse', 'Depósito', 'master', 'inventory.warehouse', 'id', 'id', 'normal', NULL),
    ('cost_center', 'Centro de custo', 'master', 'finance.cost_center', 'code', 'code', 'normal', NULL),
    ('bank_account', 'Conta bancária da empresa', 'master', 'finance.bank_account', 'code', 'code', 'normal', NULL),
    ('payment_term', 'Condição de pagamento', 'master', 'finance.payment_term', 'code', 'code', 'normal', NULL),
    ('carrier', 'Transportadora', 'master', 'logistics.carrier', 'id', 'id', 'normal', NULL),
    ('employee', 'Colaborador', 'master', 'projects.employee', 'id', 'id', 'normal', NULL),
    ('profile', 'Perfil profissional', 'master', 'projects.rate_profile', 'code', 'code', 'normal', NULL),
    ('technician', 'Técnico de campo', 'master', 'field.technician', 'employee_id', 'employee_id', 'normal', NULL),
    ('resource', 'Recurso de produção', 'master', 'production.resource', 'code', 'code', 'normal', NULL),
    ('sales_order', 'Pedido de venda', 'document', 'sales.sales_order', 'number', 'id', 'normal', NULL),
    ('purchase_request', 'Solicitação de compra', 'document', 'supply.purchase_request', 'number', 'id', 'normal', NULL),
    ('service_order', 'Ordem de serviço', 'document', 'field.service_order', 'number', 'id', 'normal', NULL),
    ('work_order', 'Ordem de produção', 'document', 'production.work_order', 'number', 'id', 'normal', NULL),
    ('project', 'Projeto', 'document', 'projects.project', 'code', 'id', 'normal', NULL),
    ('stock_movement', 'Movimento de estoque', 'document', 'inventory.stock_movement', 'id', 'id', 'high',
     'Use o gatilho de métrica (ex.: estoque do item abaixo do mínimo) ou de horário.'),
    ('journal_entry', 'Lançamento contábil', 'document', 'finance.journal_entry', 'id', 'id', 'high',
     'Use o gatilho de métrica (ex.: saldo de uma conta) ou de horário.'),
    ('time_entry', 'Apontamento de horas', 'document', 'projects.time_entry', 'id', 'id', 'high',
     'Use o gatilho de métrica (ex.: horas do projeto acima do orçamento) ou de horário.');

INSERT INTO automation.watch_field (entity, table_name, column_name, via_column, label, type, classification) VALUES
    -- Clientes e fornecedores (names and contacts of people are personal data, LGPD)
    ('party', 'base.party', 'kind', NULL, 'Tipo', 'choice', 'common'),
    ('party', 'base.party', 'name', NULL, 'Nome', 'text', 'personal'),
    ('party', 'base.party', 'tax_id', NULL, 'CNPJ/CPF', 'text', 'personal'),
    ('party', 'base.party', 'email', NULL, 'E-mail', 'text', 'personal'),
    ('party', 'base.party', 'city', NULL, 'Cidade', 'text', 'common'),
    ('party', 'base.party', 'state', NULL, 'UF', 'text', 'common'),
    ('party', 'base.party', 'address', NULL, 'Endereço (rua, número, bairro)', 'text', 'personal'),
    ('party', 'base.party', 'latitude', NULL, 'Latitude', 'number', 'personal'),
    ('party', 'base.party', 'longitude', NULL, 'Longitude', 'number', 'personal'),
    ('party', 'base.party', 'salesperson', NULL, 'Vendedor (login)', 'text', 'common'),
    ('party', 'base.party', 'active', NULL, 'Ativo', 'bool', 'common'),
    ('party', 'base.party', 'person_kind', NULL, 'Pessoa', 'choice', 'common'),
    ('party', 'base.party', 'country', NULL, 'País', 'text', 'common'),
    ('party', 'base.party', 'foreign_id', NULL, 'Identificação estrangeira', 'text', 'personal'),
    ('party', 'base.party', 'state_registration', NULL, 'Inscrição estadual', 'text', 'common'),
    ('party', 'base.party', 'icms_taxpayer', NULL, 'Contribuinte do ICMS', 'choice', 'common'),
    ('party', 'base.party', 'municipal_registration', NULL, 'Inscrição municipal', 'text', 'common'),
    ('party', 'base.party', 'tax_regime', NULL, 'Regime tributário', 'choice', 'common'),
    ('party', 'base.party', 'final_consumer', NULL, 'Consumidor final', 'bool', 'common'),
    ('party', 'finance.credit_profile', 'credit_limit', NULL, 'Crédito: Limite de crédito', 'money', 'secret'),
    ('party', 'finance.credit_profile', 'grace_days', NULL, 'Crédito: Tolerância de atraso (dias)', 'number', 'common'),
    ('party', 'finance.credit_profile', 'auto_block', NULL, 'Crédito: Bloquear automaticamente por atraso', 'bool', 'common'),
    ('party', 'finance.credit_profile', 'default_term', NULL, 'Crédito: Condição de pagamento padrão', 'ref', 'common'),
    ('party', 'base.party_bank', 'bank', NULL, 'Dados bancários: Banco', 'text', 'common'),
    ('party', 'base.party_bank', 'branch', NULL, 'Dados bancários: Agência', 'text', 'secret'),
    ('party', 'base.party_bank', 'account', NULL, 'Dados bancários: Conta', 'text', 'secret'),
    ('party', 'base.party_bank', 'kind', NULL, 'Dados bancários: Tipo de conta', 'choice', 'common'),
    ('party', 'base.party_bank', 'pix_key', NULL, 'Dados bancários: Chave PIX', 'text', 'secret'),
    ('party', 'base.party_bank', 'main', NULL, 'Dados bancários: Principal', 'bool', 'common'),
    -- Itens
    ('product', 'base.product', 'description', NULL, 'Descrição', 'text', 'common'),
    ('product', 'base.product', 'kind', NULL, 'Tipo', 'choice', 'common'),
    ('product', 'base.product', 'unit', NULL, 'Unidade', 'text', 'common'),
    ('product', 'base.product', 'price', NULL, 'Preço de venda', 'money', 'common'),
    ('product', 'base.product', 'item_group', NULL, 'Grupo de itens', 'text', 'common'),
    ('product', 'base.product', 'active', NULL, 'Ativo', 'bool', 'common'),
    ('product', 'production.item_plan', 'make_or_buy', NULL, 'Produção e custo: Origem', 'choice', 'common'),
    ('product', 'production.item_plan', 'lead_time_days', NULL, 'Produção e custo: Prazo (dias)', 'number', 'common'),
    ('product', 'production.item_plan', 'lot_min', NULL, 'Produção e custo: Lote mínimo', 'number', 'common'),
    ('product', 'production.item_plan', 'lot_multiple', NULL, 'Produção e custo: Múltiplo do lote', 'number', 'common'),
    ('product', 'production.item_plan', 'safety_stock', NULL, 'Produção e custo: Estoque de segurança', 'number', 'common'),
    ('product', 'production.item_plan', 'warehouse_id', NULL, 'Produção e custo: Depósito', 'ref', 'common'),
    ('product', 'production.item_plan', 'standard_cost', NULL, 'Produção e custo: Custo padrão unitário', 'money', 'secret'),
    ('product', 'supply.supplier_item', 'supplier_id', NULL, 'Fornecimento: Fornecedor', 'ref', 'common'),
    ('product', 'supply.supplier_item', 'price', NULL, 'Fornecimento: Preço', 'money', 'common'),
    ('product', 'supply.supplier_item', 'lead_time_days', NULL, 'Fornecimento: Prazo (dias)', 'number', 'common'),
    ('product', 'supply.supplier_item', 'min_qty', NULL, 'Fornecimento: Lote mínimo', 'number', 'common'),
    ('product', 'supply.supplier_item', 'multiple', NULL, 'Fornecimento: Múltiplo', 'number', 'common'),
    ('product', 'supply.supplier_item', 'preferred', NULL, 'Fornecimento: Preferencial', 'bool', 'common'),
    ('product', 'supply.supplier_item', 'supplier_code', NULL, 'Fornecimento: Código no fornecedor', 'text', 'common'),
    ('product', 'supply.supplier_item', 'currency', NULL, 'Fornecimento: Moeda', 'choice', 'common'),
    ('product', 'supply.supplier_item', 'valid_until', NULL, 'Fornecimento: Preço válido até', 'date', 'common'),
    ('product', 'supply.replenishment_rule', 'warehouse_id', NULL, 'Reposição: Depósito', 'ref', 'common'),
    ('product', 'supply.replenishment_rule', 'min_qty', NULL, 'Reposição: Ponto de pedido', 'number', 'common'),
    ('product', 'supply.replenishment_rule', 'max_qty', NULL, 'Reposição: Estoque máximo', 'number', 'common'),
    ('product', 'supply.replenishment_rule', 'safety_qty', NULL, 'Reposição: Segurança', 'number', 'common'),
    ('product', 'supply.replenishment_rule', 'method', NULL, 'Reposição: Método', 'choice', 'common'),
    ('product', 'supply.replenishment_rule', 'window_days', NULL, 'Reposição: Janela (dias)', 'number', 'common'),
    -- Depósitos, centros de custo, contas da empresa, condições
    ('warehouse', 'inventory.warehouse', 'description', NULL, 'Descrição', 'text', 'common'),
    ('warehouse', 'inventory.warehouse', 'cost_center', NULL, 'Centro de custo', 'ref', 'common'),
    ('warehouse', 'inventory.warehouse', 'latitude', NULL, 'Latitude', 'number', 'common'),
    ('warehouse', 'inventory.warehouse', 'longitude', NULL, 'Longitude', 'number', 'common'),
    ('warehouse', 'inventory.warehouse', 'active', NULL, 'Ativo', 'bool', 'common'),
    ('cost_center', 'finance.cost_center', 'name', NULL, 'Nome', 'text', 'common'),
    ('cost_center', 'finance.cost_center', 'parent_code', NULL, 'Centro-pai', 'ref', 'common'),
    ('cost_center', 'finance.cost_center', 'kind', NULL, 'Tipo', 'choice', 'common'),
    ('cost_center', 'finance.cost_center', 'manager', NULL, 'Responsável (usuário)', 'text', 'common'),
    ('cost_center', 'finance.cost_center', 'active', NULL, 'Ativo', 'bool', 'common'),
    ('bank_account', 'finance.bank_account', 'name', NULL, 'Nome', 'text', 'common'),
    ('bank_account', 'finance.bank_account', 'account', NULL, 'Conta contábil', 'text', 'common'),
    ('bank_account', 'finance.bank_account', 'bank', NULL, 'Banco', 'text', 'common'),
    ('bank_account', 'finance.bank_account', 'branch', NULL, 'Agência', 'text', 'secret'),
    ('bank_account', 'finance.bank_account', 'number', NULL, 'Conta', 'text', 'secret'),
    ('bank_account', 'finance.bank_account', 'active', NULL, 'Ativo', 'bool', 'common'),
    ('payment_term', 'finance.payment_term', 'name', NULL, 'Nome', 'text', 'common'),
    ('payment_term', 'finance.payment_term', 'method', NULL, 'Forma', 'choice', 'common'),
    ('payment_term', 'finance.payment_term', 'installments', NULL, 'Prazos em dias', 'text', 'common'),
    ('payment_term', 'finance.payment_term', 'down_payment_pct', NULL, 'Entrada (%)', 'number', 'common'),
    ('payment_term', 'finance.payment_term', 'adjust_pct', NULL, 'Desconto (−) ou acréscimo (+) %', 'number', 'common'),
    ('payment_term', 'finance.payment_term', 'fee_pct', NULL, 'Taxa da operadora (%)', 'number', 'common'),
    ('payment_term', 'finance.payment_term', 'min_amount', NULL, 'Valor mínimo', 'money', 'common'),
    ('payment_term', 'finance.payment_term', 'connector', NULL, 'Conector de cobrança', 'text', 'common'),
    ('payment_term', 'finance.payment_term', 'active', NULL, 'Ativo', 'bool', 'common'),
    -- Transportadoras, colaboradores, perfis, técnicos, recursos
    ('carrier', 'logistics.carrier', 'name', NULL, 'Nome', 'text', 'common'),
    ('carrier', 'logistics.carrier', 'tracking_url', NULL, 'Endereço de rastreio', 'text', 'common'),
    ('carrier', 'logistics.carrier', 'party_id', NULL, 'Fornecedor (para pagar o frete)', 'ref', 'common'),
    ('carrier', 'logistics.carrier', 'active', NULL, 'Ativo', 'bool', 'common'),
    ('carrier', 'logistics.freight_rate', 'region', NULL, 'Tabela de frete: UF de destino', 'text', 'common'),
    ('carrier', 'logistics.freight_rate', 'max_weight_kg', NULL, 'Tabela de frete: Até (kg)', 'number', 'common'),
    ('carrier', 'logistics.freight_rate', 'max_km', NULL, 'Tabela de frete: Até (km)', 'number', 'common'),
    ('carrier', 'logistics.freight_rate', 'price', NULL, 'Tabela de frete: Preço', 'money', 'common'),
    ('employee', 'projects.employee', 'name', NULL, 'Nome', 'text', 'personal'),
    ('employee', 'projects.employee', 'profile', NULL, 'Perfil profissional', 'ref', 'common'),
    ('employee', 'projects.employee', 'hourly_cost', NULL, 'Custo por hora', 'money', 'secret'),
    ('employee', 'projects.employee', 'username', NULL, 'Usuário do sistema', 'text', 'common'),
    ('employee', 'projects.employee', 'tax_id', NULL, 'CPF', 'text', 'personal'),
    ('employee', 'projects.employee', 'weekly_hours', NULL, 'Horas por semana', 'number', 'common'),
    ('employee', 'projects.employee', 'active', NULL, 'Ativo', 'bool', 'common'),
    ('profile', 'projects.rate_profile', 'description', NULL, 'Descrição', 'text', 'common'),
    ('profile', 'projects.rate_profile', 'hourly_rate', NULL, 'Valor por hora', 'money', 'common'),
    ('profile', 'projects.rate_profile', 'standard_cost', NULL, 'Custo padrão por hora', 'money', 'secret'),
    ('profile', 'projects.rate_profile', 'active', NULL, 'Ativo', 'bool', 'common'),
    ('technician', 'field.technician', 'warehouse_id', NULL, 'Depósito do veículo/maleta', 'ref', 'common'),
    ('technician', 'field.technician', 'active', NULL, 'Ativo', 'bool', 'common'),
    ('resource', 'production.resource', 'name', NULL, 'Nome', 'text', 'common'),
    ('resource', 'production.resource', 'kind', NULL, 'Tipo', 'choice', 'common'),
    ('resource', 'production.resource', 'daily_hours', NULL, 'Horas por dia', 'number', 'common'),
    ('resource', 'production.resource', 'efficiency_pct', NULL, 'Eficiência %', 'number', 'common'),
    ('resource', 'production.resource', 'cost_per_hour', NULL, 'Custo por hora', 'money', 'secret'),
    ('resource', 'production.resource', 'profile', NULL, 'Perfil (pessoas)', 'ref', 'common'),
    ('resource', 'production.resource', 'active', NULL, 'Ativo', 'bool', 'common'),
    -- Pedido de venda (items: the event carries the order's number)
    ('sales_order', 'sales.sales_order', 'status', NULL, 'Situação', 'choice', 'common'),
    ('sales_order', 'sales.sales_order', 'customer_id', NULL, 'Cliente', 'ref', 'common'),
    ('sales_order', 'sales.sales_order', 'warehouse_id', NULL, 'Depósito', 'ref', 'common'),
    ('sales_order', 'sales.sales_order', 'order_date', NULL, 'Data do pedido', 'date', 'common'),
    ('sales_order', 'sales.sales_order', 'total', NULL, 'Valor total', 'money', 'common'),
    ('sales_order', 'sales.sales_order', 'notes', NULL, 'Observações', 'text', 'common'),
    ('sales_order', 'sales.sales_order', 'cost_center', NULL, 'Centro de custo', 'ref', 'common'),
    ('sales_order', 'sales.sales_order', 'payment_term', NULL, 'Condição de pagamento', 'ref', 'common'),
    ('sales_order', 'sales.sales_order', 'salesperson', NULL, 'Vendedor', 'text', 'common'),
    ('sales_order', 'sales.sales_order', 'fulfillment', NULL, 'Atendimento', 'choice', 'common'),
    ('sales_order', 'sales.sales_order_item', 'promised_date', 'order_id', 'Item: Data de entrega prometida', 'date', 'common'),
    ('sales_order', 'sales.sales_order_item', 'quantity', 'order_id', 'Item: Quantidade', 'number', 'common'),
    ('sales_order', 'sales.sales_order_item', 'price', 'order_id', 'Item: Preço', 'money', 'common'),
    -- Solicitação de compra
    ('purchase_request', 'supply.purchase_request', 'status', NULL, 'Situação', 'choice', 'common'),
    ('purchase_request', 'supply.purchase_request', 'need_date', NULL, 'Data de necessidade', 'date', 'common'),
    ('purchase_request', 'supply.purchase_request', 'total', NULL, 'Valor total', 'money', 'common'),
    ('purchase_request', 'supply.purchase_request', 'cost_center', NULL, 'Centro de custo', 'ref', 'common'),
    ('purchase_request', 'supply.purchase_request', 'warehouse_id', NULL, 'Depósito', 'ref', 'common'),
    ('purchase_request', 'supply.purchase_request', 'reason', NULL, 'Motivo', 'text', 'common'),
    ('purchase_request', 'supply.purchase_request', 'requester', NULL, 'Solicitante', 'text', 'common'),
    ('purchase_request', 'supply.purchase_request_line', 'quantity', 'request_id', 'Item: Quantidade', 'number', 'common'),
    ('purchase_request', 'supply.purchase_request_line', 'est_price', 'request_id', 'Item: Preço estimado', 'money', 'common'),
    ('purchase_request', 'supply.purchase_request_line', 'supplier_id', 'request_id', 'Item: Fornecedor', 'ref', 'common'),
    -- Ordem de serviço (the technician is the assignment)
    ('service_order', 'field.service_order', 'status', NULL, 'Situação', 'choice', 'common'),
    ('service_order', 'field.service_order', 'priority', NULL, 'Prioridade', 'choice', 'common'),
    ('service_order', 'field.service_order', 'due_at', NULL, 'Prazo', 'datetime', 'common'),
    ('service_order', 'field.service_order', 'customer_id', NULL, 'Cliente', 'ref', 'common'),
    ('service_order', 'field.service_order', 'site_address', NULL, 'Endereço do atendimento', 'text', 'personal'),
    ('service_order', 'field.service_order', 'contact', NULL, 'Contato', 'text', 'personal'),
    ('service_order', 'field.service_order', 'description', NULL, 'Descrição', 'text', 'common'),
    ('service_order', 'field.assignment', 'employee_id', 'order_id', 'Agenda: Técnico', 'ref', 'common'),
    ('service_order', 'field.assignment', 'period', 'order_id', 'Agenda: Horário', 'text', 'common'),
    ('service_order', 'field.assignment', 'status', 'order_id', 'Agenda: Situação', 'choice', 'common'),
    -- Ordem de produção
    ('work_order', 'production.work_order', 'status', NULL, 'Situação', 'choice', 'common'),
    ('work_order', 'production.work_order', 'quantity', NULL, 'Quantidade', 'number', 'common'),
    ('work_order', 'production.work_order', 'start_date', NULL, 'Início', 'date', 'common'),
    ('work_order', 'production.work_order', 'due_date', NULL, 'Data de entrega', 'date', 'common'),
    ('work_order', 'production.work_order', 'priority', NULL, 'Prioridade', 'number', 'common'),
    ('work_order', 'production.work_order', 'warehouse_id', NULL, 'Depósito', 'ref', 'common'),
    -- Projeto
    ('project', 'projects.project', 'status', NULL, 'Situação', 'choice', 'common'),
    ('project', 'projects.project', 'manager', NULL, 'Gerente', 'text', 'common'),
    ('project', 'projects.project', 'customer_id', NULL, 'Cliente', 'ref', 'common'),
    ('project', 'projects.project', 'billing', NULL, 'Faturamento', 'choice', 'common'),
    ('project', 'projects.project', 'start_date', NULL, 'Início', 'date', 'common'),
    ('project', 'projects.project', 'due_date', NULL, 'Data de entrega', 'date', 'common'),
    ('project', 'projects.project', 'budget_hours', NULL, 'Orçamento (horas)', 'number', 'common'),
    ('project', 'projects.project', 'budget_amount', NULL, 'Orçamento (valor)', 'money', 'common');

-- What the screens and the rules read: the product's fields and the company's own fields, in one list.
CREATE VIEW automation.watchable AS
SELECT f.entity, e.label AS entity_label, e.source, f.table_name, f.column_name AS field, f.via_column, f.label, f.type,
       f.classification, false AS custom
  FROM automation.watch_field f JOIN automation.watch_entity e USING (entity)
UNION ALL
SELECT c.entity, e.label, e.source, e.table_name, 'custom.' || c.name, NULL, c.label,
       CASE c.type WHEN 'int' THEN 'number' WHEN 'decimal' THEN 'number' WHEN 'money' THEN 'money' WHEN 'date' THEN 'date'
                   WHEN 'bool' THEN 'bool' WHEN 'choice' THEN 'choice' ELSE 'text' END,
       c.classification, true
  FROM master.custom_field c JOIN automation.watch_entity e ON e.entity = c.entity AND e.source = 'master'
 WHERE c.active;

REVOKE ALL ON FUNCTION automation.check_watchable() FROM PUBLIC;
GRANT SELECT ON automation.watch_entity, automation.watch_field, automation.watchable TO ana_exec, ana_read;
GRANT USAGE ON SCHEMA automation TO ana_read;
