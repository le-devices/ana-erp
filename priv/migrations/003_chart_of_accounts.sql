-- 003 — Base chart of accounts shipped with the product (customers may extend it)

INSERT INTO finance.account (code, description, nature, postable) VALUES
    ('1', 'Ativo', 'asset', false),
    ('1.1', 'Ativo circulante', 'asset', false),
    ('1.1.1', 'Caixa e bancos', 'asset', true),
    ('1.1.2', 'Clientes', 'asset', true),
    ('1.1.3', 'Estoques', 'asset', true),
    ('2', 'Passivo', 'liability', false),
    ('2.1.1', 'Fornecedores', 'liability', true),
    ('3', 'Patrimônio líquido', 'equity', false),
    ('3.1.1', 'Capital social', 'equity', true),
    ('4', 'Receitas', 'revenue', false),
    ('4.1.1', 'Receita de vendas', 'revenue', true),
    ('5', 'Despesas', 'expense', false),
    ('5.1.1', 'Custo das mercadorias vendidas', 'expense', true)
ON CONFLICT DO NOTHING;
