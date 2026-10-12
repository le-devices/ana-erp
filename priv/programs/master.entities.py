# ana:description Definição das entidades mestres do produto (cadastros): campos, abas, validação, duplicados e qualidade
# ana:kind library
"""Spec 040 (RF-040-01). One declaration per master entity; the service (master.core) builds the list,
the record sheet, the search, import/export, history and quality from it. A seed program: product
improvements arrive as product updates (spec 028); the client may adapt them.

Entity keys
  label, plural, group          names on screen and the group in the Cadastros menu
  table                         main table (schema.table)
  id                            column that identifies the row (history, children, references)
  key                           business key shown and used to open the record (often = id)
  title                         SQL expression over the main table (alias t) naming the record
  search                        SQL expression searched with base.norm (trigram index when present)
  writer                        program that saves (business rules live there); writer_key = its
                                parameter for the key of an existing record (None: upserts by a field)
  writer_active                 the writer has an `active` parameter (the current value is passed)
  fields                        name (column), label, type, required, choices, ref (entity), param
                                (writer parameter, when different), ref_param ('key' of the referenced
                                entity instead of its id), readonly (after creation), list, sensitive,
                                secret (only admins see it), expr (read expression), help
  tabs                          kind 'one' (1:1 row) or 'rows' (1:N) or 'view' (read only SQL)
  duplicates                    [{"field", "kind": "exact" | "similar", "threshold"}]
  quality                       [{"label", "where" (over alias t), "hint"}]
  permissions                   minimum role per action: view, edit, approve
Types: text, int, decimal, money, percent, bool, date, choice, ref, email, tax_id, state, url.
"""

YES_NO = [["true", "Sim"], ["false", "Não"]]

ENTITIES = {
    "party": {
        "label": "Cliente ou fornecedor", "plural": "Clientes e fornecedores", "group": "Parceiros",
        "table": "base.party", "id": "id", "key": "id", "title": "t.name",
        "search": "base.norm(t.name)", "order": "t.name",
        "writer": "base.save_party", "writer_key": "id",
        "custom": True,
        "fields": [
            {"name": "kind", "label": "Tipo", "type": "choice", "required": True, "list": True, "default": "customer",
             "choices": [["customer", "Cliente"], ["supplier", "Fornecedor"], ["both", "Cliente e fornecedor"]]},
            {"name": "name", "label": "Nome", "type": "text", "required": True, "list": True, "max": 200},
            {"name": "tax_id", "label": "CNPJ/CPF", "type": "tax_id", "list": True},
            {"name": "email", "label": "E-mail", "type": "email", "list": True},
            {"name": "city", "label": "Cidade", "type": "text", "list": True, "max": 100},
            {"name": "state", "label": "UF", "type": "state", "list": True},
            {"name": "address", "label": "Endereço (rua, número, bairro)", "type": "text", "max": 300},
            {"name": "latitude", "label": "Latitude", "type": "decimal", "help": "ex.: -23,5505"},
            {"name": "longitude", "label": "Longitude", "type": "decimal", "help": "ex.: -46,6333"},
        ],
        "tabs": [
            {"label": "Crédito", "kind": "one", "table": "finance.credit_profile", "fk": "party_id",
             "writer": "finance.save_credit_profile", "parent_param": "customer", "parent_value": "id",
             "fields": [
                 {"name": "credit_limit", "label": "Limite de crédito", "type": "money", "sensitive": True,
                  "help": "vazio = sem limite"},
                 {"name": "grace_days", "label": "Tolerância de atraso (dias)", "type": "int", "help": "vazio = política"},
                 {"name": "auto_block", "label": "Bloquear automaticamente por atraso", "type": "bool"},
                 {"name": "default_term", "label": "Condição de pagamento padrão", "type": "ref", "ref": "payment_term"},
             ]},
            {"label": "Saldos", "kind": "view", "sql":
                "SELECT CASE b.kind WHEN 'receivable' THEN 'A receber' ELSE 'A pagar' END AS \"tipo\", count(*) AS \"títulos\", "
                "sum(b.amount) AS \"em aberto\", min(b.due_date) AS \"próximo vencimento\" "
                "FROM finance.bill b WHERE b.party_id = $1 AND b.status = 'open' GROUP BY b.kind"},
        ],
        "duplicates": [{"field": "tax_id", "kind": "exact"}, {"field": "name", "kind": "similar", "threshold": 0.55},
                       {"field": "email", "kind": "exact"}],
        "quality": [
            {"label": "Sem CNPJ/CPF", "where": "t.tax_id IS NULL", "hint": "Preencha o documento: evita duplicados e é exigido nas notas."},
            {"label": "Sem e-mail", "where": "t.email IS NULL", "hint": "Sem e-mail o ERP não envia documentos e avisos."},
            {"label": "Sem coordenadas", "where": "t.latitude IS NULL AND t.kind <> 'supplier'",
             "hint": "Use a geocodificação (base.geocode) para calcular distâncias."},
        ],
        "permissions": {"view": "user", "edit": "user", "approve": "admin"},
    },
    "product": {
        "label": "Item", "plural": "Itens (mercadorias e serviços)", "group": "Itens e estoque",
        "table": "base.product", "id": "id", "key": "code", "title": "t.code || ' — ' || t.description",
        "search": "base.norm(t.code || ' ' || t.description)", "order": "t.code",
        "writer": "base.save_product", "writer_key": None,
        "custom": True,
        "fields": [
            {"name": "code", "label": "Código", "type": "text", "required": True, "readonly": True, "list": True, "max": 40,
             "upper": True},
            {"name": "description", "label": "Descrição", "type": "text", "required": True, "list": True, "max": 200},
            {"name": "kind", "label": "Tipo", "type": "choice", "required": True, "list": True, "default": "goods",
             "choices": [["goods", "Mercadoria (controla estoque)"], ["service", "Serviço"]]},
            {"name": "unit", "label": "Unidade", "type": "text", "default": "UN", "list": True, "max": 6, "upper": True},
            {"name": "price", "label": "Preço de venda", "type": "money", "required": True, "list": True, "sensitive": True},
        ],
        "tabs": [
            {"label": "Produção e custo", "kind": "one", "table": "production.item_plan", "fk": "product_id",
             "writer": "production.save_item_plan", "parent_param": "product", "parent_value": "key",
             "fields": [
                 {"name": "make_or_buy", "label": "Origem", "type": "choice", "default": "buy",
                  "choices": [["make", "Fabricar"], ["buy", "Comprar"]]},
                 {"name": "lead_time_days", "label": "Prazo (dias)", "type": "int"},
                 {"name": "lot_min", "label": "Lote mínimo", "type": "decimal"},
                 {"name": "lot_multiple", "label": "Múltiplo do lote", "type": "decimal"},
                 {"name": "safety_stock", "label": "Estoque de segurança", "type": "decimal"},
                 {"name": "warehouse_id", "label": "Depósito", "type": "ref", "ref": "warehouse", "param": "warehouse",
                  "ref_param": "key"},
                 {"name": "standard_cost", "label": "Custo padrão unitário", "type": "money", "sensitive": True},
             ]},
            {"label": "Fornecimento", "kind": "rows", "table": "supply.supplier_item", "fk": "product_id",
             "row_key": ["supplier_id"], "writer": "supply.save_supplier_item", "parent_param": "product",
             "parent_value": "key", "remove": "delete",
             "fields": [
                 {"name": "supplier_id", "label": "Fornecedor", "type": "ref", "ref": "party", "param": "supplier",
                  "required": True, "filter": "t.kind IN ('supplier', 'both')"},
                 {"name": "price", "label": "Preço", "type": "money", "required": True},
                 {"name": "lead_time_days", "label": "Prazo (dias)", "type": "int"},
                 {"name": "min_qty", "label": "Lote mínimo", "type": "decimal"},
                 {"name": "multiple", "label": "Múltiplo", "type": "decimal"},
                 {"name": "preferred", "label": "Preferencial", "type": "bool"},
                 {"name": "supplier_code", "label": "Código no fornecedor", "type": "text"},
                 {"name": "currency", "label": "Moeda", "type": "choice", "default": "BRL",
                  "choices": [["BRL", "Real"], ["USD", "Dólar"], ["EUR", "Euro"]]},
                 {"name": "valid_until", "label": "Preço válido até", "type": "date"},
             ]},
            {"label": "Reposição", "kind": "rows", "table": "supply.replenishment_rule", "fk": "product_id",
             "row_key": ["warehouse_id"], "writer": "supply.save_replenishment_rule", "parent_param": "product",
             "parent_value": "key", "remove": "param:remove",
             "fields": [
                 {"name": "warehouse_id", "label": "Depósito", "type": "ref", "ref": "warehouse", "param": "warehouse",
                  "ref_param": "key", "required": True},
                 {"name": "min_qty", "label": "Ponto de pedido", "type": "decimal", "required": True},
                 {"name": "max_qty", "label": "Estoque máximo", "type": "decimal", "required": True},
                 {"name": "safety_qty", "label": "Segurança", "type": "decimal"},
                 {"name": "method", "label": "Método", "type": "choice", "default": "min_max",
                  "choices": [["min_max", "Mínimo e máximo"], ["average_consumption", "Consumo médio × prazo"]]},
                 {"name": "window_days", "label": "Janela (dias)", "type": "int"},
             ]},
            {"label": "Estoque", "kind": "view", "sql":
                "SELECT w.code AS \"depósito\", w.description AS \"descrição\", sum(m.quantity) AS \"saldo\" "
                "FROM inventory.stock_movement m JOIN inventory.warehouse w ON w.id = m.warehouse_id "
                "WHERE m.product_id = $1 GROUP BY w.code, w.description HAVING sum(m.quantity) <> 0 ORDER BY w.code",
             "after": "SELECT quantity AS \"quantidade própria\", avg_cost AS \"custo médio\", value AS \"valor\" "
                      "FROM inventory.item_cost WHERE product_id = $1"},
        ],
        "duplicates": [{"field": "description", "kind": "similar", "threshold": 0.7}],
        "quality": [
            {"label": "Mercadoria sem custo", "where": "t.kind = 'goods' AND NOT EXISTS (SELECT 1 FROM production.item_plan p "
             "WHERE p.product_id = t.id AND p.standard_cost IS NOT NULL) AND COALESCE((SELECT avg_cost FROM inventory.item_cost c "
             "WHERE c.product_id = t.id), 0) = 0", "hint": "Sem custo, o estoque entra sem valor: informe o custo padrão."},
            {"label": "Mercadoria sem fornecedor", "where": "t.kind = 'goods' AND NOT EXISTS (SELECT 1 FROM supply.supplier_item s "
             "WHERE s.product_id = t.id) AND NOT EXISTS (SELECT 1 FROM production.item_plan p WHERE p.product_id = t.id "
             "AND p.make_or_buy = 'make')", "hint": "A sugestão de compra precisa de um fornecedor."},
            {"label": "Preço zerado", "where": "t.price = 0", "hint": "Item vendável com preço zero."},
        ],
        "permissions": {"view": "user", "edit": "user", "approve": "admin"},
    },
    "warehouse": {
        "label": "Depósito", "plural": "Depósitos", "group": "Itens e estoque",
        "table": "inventory.warehouse", "id": "id", "key": "code", "title": "t.code || ' — ' || t.description",
        "search": "base.norm(t.code || ' ' || t.description)", "order": "t.code",
        "writer": "inventory.save_warehouse", "writer_key": None,
        "fields": [
            {"name": "code", "label": "Código", "type": "text", "required": True, "readonly": True, "list": True, "upper": True},
            {"name": "description", "label": "Descrição", "type": "text", "required": True, "list": True},
            {"name": "cost_center", "label": "Centro de custo", "type": "ref", "ref": "cost_center", "list": True},
            {"name": "latitude", "label": "Latitude", "type": "decimal"},
            {"name": "longitude", "label": "Longitude", "type": "decimal"},
        ],
        "quality": [{"label": "Sem centro de custo", "where": "t.cost_center IS NULL AND t.code NOT IN ('TRANSITO', 'QUARENTENA')",
                     "hint": "Custos e receitas do depósito caem no centro de custo da empresa."}],
        "permissions": {"view": "user", "edit": "developer", "approve": "admin"},
    },
    "cost_center": {
        "label": "Centro de custo", "plural": "Centros de custo", "group": "Finanças",
        "table": "finance.cost_center", "id": "code", "key": "code", "title": "t.code || ' — ' || t.name",
        "search": "base.norm(t.code || ' ' || t.name)", "order": "t.code",
        "writer": "finance.save_cost_center", "writer_key": None, "writer_active": True,
        "fields": [
            {"name": "code", "label": "Código", "type": "text", "required": True, "readonly": True, "list": True, "upper": True},
            {"name": "name", "label": "Nome", "type": "text", "required": True, "list": True},
            {"name": "parent_code", "label": "Centro-pai", "type": "ref", "ref": "cost_center", "param": "parent", "list": True},
            {"name": "kind", "label": "Tipo", "type": "choice", "list": True,
             "choices": [["operational", "Operacional"], ["administrative", "Administrativo"], ["commercial", "Comercial"],
                         ["project", "Projeto"], ["other", "Outro"]]},
            {"name": "manager", "label": "Responsável (usuário)", "type": "text"},
        ],
        "permissions": {"view": "user", "edit": "admin", "approve": "admin"},
    },
    "bank_account": {
        "label": "Conta bancária", "plural": "Contas bancárias", "group": "Finanças",
        "table": "finance.bank_account", "id": "code", "key": "code", "title": "t.code || ' — ' || t.name",
        "search": "base.norm(t.code || ' ' || t.name)", "order": "t.code",
        "writer": "finance.save_bank_account", "writer_key": None, "writer_active": True,
        "fields": [
            {"name": "code", "label": "Código", "type": "text", "required": True, "readonly": True, "list": True, "upper": True},
            {"name": "name", "label": "Nome", "type": "text", "required": True, "list": True},
            {"name": "account", "label": "Conta contábil", "type": "lookup", "required": True, "list": True, "sensitive": True,
             "lookup": {"program": "finance.lookup", "params": {"kind": "accounts"}}},
            {"name": "bank", "label": "Banco", "type": "text", "list": True},
            {"name": "branch", "label": "Agência", "type": "text", "sensitive": True},
            {"name": "number", "label": "Conta", "type": "text", "sensitive": True},
        ],
        "permissions": {"view": "user", "edit": "admin", "approve": "admin"},
    },
    "payment_term": {
        "label": "Condição de pagamento", "plural": "Condições de pagamento", "group": "Finanças",
        "table": "finance.payment_term", "id": "code", "key": "code", "title": "t.name || ' (' || t.code || ')'",
        "search": "base.norm(t.code || ' ' || t.name)", "order": "t.name",
        "writer": "finance.save_payment_term", "writer_key": None, "writer_active": True,
        "fields": [
            {"name": "code", "label": "Código", "type": "text", "required": True, "readonly": True, "list": True, "upper": True},
            {"name": "name", "label": "Nome", "type": "text", "required": True, "list": True},
            {"name": "method", "label": "Forma", "type": "choice", "required": True, "list": True,
             "choices": [["pix", "PIX"], ["boleto", "Boleto"], ["credit_card", "Cartão de crédito"], ["debit_card", "Cartão de débito"],
                         ["direct", "Depósito/transferência"], ["cash", "Dinheiro"]]},
            {"name": "installments", "label": "Prazos em dias (ex.: 30/60/90; 0 = à vista)", "type": "text", "list": True,
             "expr": "(SELECT string_agg(x ->> 'days', '/' ORDER BY o) FROM jsonb_array_elements(t.installments) "
                     "WITH ORDINALITY AS a(x, o))",
             "unchanged_param": "schedule", "unchanged_expr": "t.installments"},
            {"name": "down_payment_pct", "label": "Entrada (%)", "type": "percent"},
            {"name": "adjust_pct", "label": "Desconto (−) ou acréscimo (+) %", "type": "decimal"},
            {"name": "fee_pct", "label": "Taxa da operadora (%)", "type": "percent"},
            {"name": "min_amount", "label": "Valor mínimo", "type": "money"},
            {"name": "connector", "label": "Conector de cobrança", "type": "text"},
        ],
        "permissions": {"view": "user", "edit": "admin", "approve": "admin"},
    },
    "carrier": {
        "label": "Transportadora", "plural": "Transportadoras", "group": "Logística",
        "table": "logistics.carrier", "id": "id", "key": "id", "title": "t.name",
        "search": "base.norm(t.name)", "order": "t.name",
        "writer": "logistics.save_carrier", "writer_key": None, "writer_active": True,
        "fields": [
            {"name": "name", "label": "Nome", "type": "text", "required": True, "readonly": True, "list": True},
            {"name": "tracking_url", "label": "Endereço de rastreio (use {codigo})", "type": "url"},
            {"name": "party_id", "label": "Fornecedor (para pagar o frete)", "type": "ref", "ref": "party", "list": True,
             "readonly": True, "computed": True},
        ],
        "tabs": [
            {"label": "Tabela de frete", "kind": "rows", "table": "logistics.freight_rate", "fk": "carrier_id",
             "row_key": ["region", "max_weight_kg", "max_km"], "list_param": "rates",
             "fields": [
                 {"name": "region", "label": "UF de destino (* = demais)", "type": "text", "default": "*", "upper": True},
                 {"name": "max_weight_kg", "label": "Até (kg)", "type": "decimal", "required": True},
                 {"name": "max_km", "label": "Até (km; vazio = qualquer)", "type": "decimal"},
                 {"name": "price", "label": "Preço", "type": "money", "required": True},
             ]},
        ],
        "permissions": {"view": "user", "edit": "user", "approve": "admin"},
    },
    "employee": {
        "label": "Colaborador", "plural": "Colaboradores", "group": "Pessoas",
        "table": "projects.employee", "id": "id", "key": "id", "title": "t.name",
        "search": "base.norm(t.name)", "order": "t.name",
        "writer": "projects.save_employee", "writer_key": "id", "writer_active": True,
        "fields": [
            {"name": "name", "label": "Nome", "type": "text", "required": True, "list": True},
            {"name": "profile", "label": "Perfil profissional", "type": "ref", "ref": "profile", "required": True, "list": True},
            {"name": "hourly_cost", "label": "Custo por hora", "type": "money", "secret": True, "sensitive": True},
            {"name": "username", "label": "Usuário do sistema", "type": "text", "list": True},
        ],
        "permissions": {"view": "user", "edit": "user", "approve": "admin"},
    },
    "profile": {
        "label": "Perfil profissional", "plural": "Perfis profissionais", "group": "Pessoas",
        "table": "projects.rate_profile", "id": "code", "key": "code", "title": "t.code || ' — ' || t.description",
        "search": "base.norm(t.code || ' ' || t.description)", "order": "t.code",
        "writer": "projects.save_profile", "writer_key": None, "writer_active": True,
        "fields": [
            {"name": "code", "label": "Código", "type": "text", "required": True, "readonly": True, "list": True, "upper": True},
            {"name": "description", "label": "Descrição", "type": "text", "required": True, "list": True},
            {"name": "hourly_rate", "label": "Valor por hora", "type": "money", "required": True, "list": True, "sensitive": True},
        ],
        "permissions": {"view": "user", "edit": "user", "approve": "admin"},
    },
    "technician": {
        "label": "Técnico de campo", "plural": "Técnicos de campo", "group": "Pessoas",
        "table": "field.technician", "id": "employee_id", "key": "employee_id",
        "title": "(SELECT e.name FROM projects.employee e WHERE e.id = t.employee_id)",
        "search": "base.norm((SELECT e.name FROM projects.employee e WHERE e.id = t.employee_id))", "order": "1",
        "writer": "field.save_technician", "writer_key": None, "writer_active": True,
        "fields": [
            {"name": "employee_id", "label": "Colaborador", "type": "ref", "ref": "employee", "param": "employee",
             "required": True, "readonly": True, "list": True},
            {"name": "warehouse_id", "label": "Depósito do veículo/maleta", "type": "ref", "ref": "warehouse",
             "param": "warehouse", "ref_param": "key", "list": True},
        ],
        "permissions": {"view": "user", "edit": "user", "approve": "admin"},
    },
    "resource": {
        "label": "Recurso de produção", "plural": "Recursos de produção", "group": "Produção",
        "table": "production.resource", "id": "code", "key": "code", "title": "t.code || ' — ' || t.name",
        "search": "base.norm(t.code || ' ' || t.name)", "order": "t.code",
        "writer": "production.save_resource", "writer_key": None, "writer_active": True,
        "fields": [
            {"name": "code", "label": "Código", "type": "text", "required": True, "readonly": True, "list": True, "upper": True},
            {"name": "name", "label": "Nome", "type": "text", "required": True, "list": True},
            {"name": "kind", "label": "Tipo", "type": "choice", "list": True, "default": "bench",
             "choices": [["machine", "Máquina"], ["bench", "Bancada"], ["line", "Linha"], ["people", "Pessoas"]]},
            {"name": "daily_hours", "label": "Horas por dia", "type": "decimal", "list": True},
            {"name": "efficiency_pct", "label": "Eficiência %", "type": "percent"},
            {"name": "cost_per_hour", "label": "Custo por hora", "type": "money", "sensitive": True},
            {"name": "profile", "label": "Perfil (pessoas)", "type": "ref", "ref": "profile"},
        ],
        "permissions": {"view": "user", "edit": "user", "approve": "admin"},
    },
}

GROUPS = ["Parceiros", "Itens e estoque", "Finanças", "Logística", "Pessoas", "Produção"]
