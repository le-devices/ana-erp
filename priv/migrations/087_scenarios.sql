-- 087 — Scenarios "what if" (spec 069, T-069-03, RF-069-02, D2).
--
-- A scenario is a set of named shocks over the base projection. The kinds of shock are data: a closed list that
-- grows by a row here and a reviewed function in the library scenario.shocks (spec 064's gate). Simulating never
-- writes (D4): only the scenario's definition is saved, one row per scenario (spec 063: one write per save).
CREATE SCHEMA scenario;

CREATE TABLE scenario.shock_kind (
    code        text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,40}$'),
    name        text NOT NULL CHECK (length(btrim(name)) BETWEEN 3 AND 80),
    description text NOT NULL CHECK (length(btrim(description)) BETWEEN 3 AND 400),
    -- [{name, type, label, required, choices?}] — type: currency, percent, date, days, supplier, customer, item,
    -- group, resource, tax_rule, value_name, value, choice.
    params      jsonb NOT NULL CHECK (jsonb_typeof(params) = 'array'),
    function    text NOT NULL CHECK (function ~ '^[a-z][a-z0-9_]{1,62}$'),
    sequence    integer NOT NULL DEFAULT 100,
    active      boolean NOT NULL DEFAULT true
);

CREATE TABLE scenario.scenario (
    id          bigserial PRIMARY KEY,
    name        text NOT NULL CHECK (length(btrim(name)) BETWEEN 3 AND 120),
    description text NOT NULL DEFAULT '' CHECK (length(description) <= 2000),
    owner       text NOT NULL REFERENCES ana_system.app_user(username) ON UPDATE CASCADE,
    -- [{kind, params}] validated by scenario.shocks.validate before every save.
    shocks      jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(shocks) = 'array' AND jsonb_array_length(shocks) <= 30),
    -- Shared with a group (D8): its members see and combine it, each one with their own data scope.
    shared_group text REFERENCES ana_system.access_group(name) ON UPDATE CASCADE ON DELETE SET NULL,
    version     integer NOT NULL DEFAULT 1,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner, name)
);
CREATE INDEX scenario_group_idx ON scenario.scenario (shared_group) WHERE shared_group IS NOT NULL;

INSERT INTO scenario.shock_kind (code, name, description, params, function, sequence) VALUES
('currency', 'Câmbio', 'Uma moeda varia um percentual a partir de uma data: compras, pagamentos e custo dos itens que usam o que vem de fora',
 '[{"name":"currency","type":"currency","label":"moeda","required":true},
   {"name":"pct","type":"percent","label":"variação (%)","required":true},
   {"name":"from","type":"date","label":"a partir de","required":false}]', 'currency', 10),
('purchase_price', 'Preço de compra', 'O preço de compra de um item ou de um grupo de itens varia um percentual a partir de uma data',
 '[{"name":"item","type":"item","label":"item","required":false},
   {"name":"group","type":"group","label":"grupo de itens","required":false},
   {"name":"pct","type":"percent","label":"variação (%)","required":true},
   {"name":"from","type":"date","label":"a partir de","required":false}]', 'purchase_price', 20),
('supplier_delay', 'Fornecedor atrasa', 'As entregas de um fornecedor chegam alguns dias depois do que o histórico mostra',
 '[{"name":"supplier","type":"supplier","label":"fornecedor","required":true},
   {"name":"days","type":"days","label":"dias a mais","required":true}]', 'supplier_delay', 30),
('supplier_stops', 'Fornecedor deixa de entregar', 'O que um fornecedor entregaria a partir de uma data não chega',
 '[{"name":"supplier","type":"supplier","label":"fornecedor","required":true},
   {"name":"from","type":"date","label":"a partir de","required":false}]', 'supplier_stops', 40),
('customer_delay', 'Cliente atrasa o pagamento', 'Um cliente paga alguns dias depois do que o histórico mostra',
 '[{"name":"customer","type":"customer","label":"cliente","required":true},
   {"name":"days","type":"days","label":"dias a mais","required":true}]', 'customer_delay', 50),
('customer_stops', 'Cliente deixa de pagar', 'O que um cliente pagaria a partir de uma data não entra no caixa',
 '[{"name":"customer","type":"customer","label":"cliente","required":true},
   {"name":"from","type":"date","label":"a partir de","required":false}]', 'customer_stops', 60),
('payment_terms', 'Prazo de recebimento ou de pagamento', 'Os pedidos passam a ser recebidos ou pagos alguns dias antes ou depois',
 '[{"name":"side","type":"choice","label":"prazo","required":true,"choices":[["receive","de recebimento"],["pay","de pagamento"]]},
   {"name":"days","type":"days","label":"dias (negativo antecipa)","required":true}]', 'payment_terms', 70),
('sales_volume', 'Volume de vendas', 'As vendas de um item, de um grupo ou de um cliente variam um percentual',
 '[{"name":"item","type":"item","label":"item","required":false},
   {"name":"group","type":"group","label":"grupo de itens","required":false},
   {"name":"customer","type":"customer","label":"cliente","required":false},
   {"name":"pct","type":"percent","label":"variação (%)","required":true}]', 'sales_volume', 80),
('capacity', 'Capacidade de um recurso', 'Um recurso produz menos num período (máquina parada, técnico de férias)',
 '[{"name":"resource","type":"resource","label":"recurso","required":true},
   {"name":"pct","type":"percent","label":"queda (%) — 100 é parado","required":true},
   {"name":"from","type":"date","label":"de","required":false},
   {"name":"until","type":"date","label":"até","required":true}]', 'capacity', 90),
('tax_rule', 'Regra de imposto', 'Uma regra de imposto em rascunho passa a valer a partir de uma data, só neste cenário',
 '[{"name":"rule","type":"tax_rule","label":"regra em rascunho","required":true},
   {"name":"from","type":"date","label":"a partir de","required":false}]', 'tax_rule', 100),
('company_value', 'Valor da empresa', 'Um valor da empresa muda a partir de uma data, só neste cenário',
 '[{"name":"name","type":"value_name","label":"valor","required":true},
   {"name":"value","type":"value","label":"novo conteúdo","required":true},
   {"name":"from","type":"date","label":"a partir de","required":false}]', 'company_value', 110);

GRANT USAGE ON SCHEMA scenario TO ana_exec, ana_read;
GRANT SELECT ON scenario.shock_kind TO ana_exec, ana_read;
GRANT SELECT, INSERT, UPDATE, DELETE ON scenario.scenario TO ana_exec;
GRANT USAGE ON SEQUENCE scenario.scenario_id_seq TO ana_exec;
