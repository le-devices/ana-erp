-- Demo: commerce (RF-006-07). Applied only with ANA_DEMO=true.

INSERT INTO base.company (legal_name, tax_id, city, state) VALUES
    ('ANA Demonstração Ltda', '00.000.000/0001-00', 'São Paulo', 'SP')
ON CONFLICT DO NOTHING;

INSERT INTO base.party (kind, name, tax_id, email, city, state) VALUES
    ('customer', 'Mercado Bom Preço', '11.111.111/0001-11', 'compras@bompreco.example', 'Campinas', 'SP'),
    ('customer', 'Padaria Pão Quente', '22.222.222/0001-22', 'contato@paoquente.example', 'Curitiba', 'PR'),
    ('customer', 'Loja Esquina', '33.333.333/0001-33', 'loja@esquina.example', 'Recife', 'PE'),
    ('supplier', 'Distribuidora Norte', '44.444.444/0001-44', 'vendas@norte.example', 'Manaus', 'AM')
ON CONFLICT DO NOTHING;

INSERT INTO base.product (code, description, unit, price) VALUES
    ('CAFE-500', 'Café torrado 500 g', 'UN', 18.90),
    ('ARROZ-5', 'Arroz tipo 1 5 kg', 'UN', 27.50),
    ('FEIJAO-1', 'Feijão carioca 1 kg', 'UN', 8.99),
    ('OLEO-900', 'Óleo de soja 900 ml', 'UN', 7.49),
    ('ACUCAR-1', 'Açúcar cristal 1 kg', 'UN', 4.79)
ON CONFLICT DO NOTHING;

INSERT INTO inventory.warehouse (code, description) VALUES
    ('CENTRAL', 'Depósito central'),
    ('LOJA', 'Depósito da loja')
ON CONFLICT DO NOTHING;

INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, created_by)
SELECT p.id, w.id, q.qty, 'in', 'OPENING-BALANCE', 'system'
FROM (VALUES ('CAFE-500', 'CENTRAL', 200), ('ARROZ-5', 'CENTRAL', 150),
             ('FEIJAO-1', 'CENTRAL', 300), ('OLEO-900', 'CENTRAL', 120),
             ('ACUCAR-1', 'CENTRAL', 250), ('CAFE-500', 'LOJA', 30),
             ('ARROZ-5', 'LOJA', 20)) AS q(product, warehouse, qty)
JOIN base.product p ON p.code = q.product
JOIN inventory.warehouse w ON w.code = q.warehouse;
