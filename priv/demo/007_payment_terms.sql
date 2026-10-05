-- Demo: payment terms offered to customers (spec 031). Applied only with ANA_DEMO=true.
INSERT INTO finance.payment_term (code, name, method, installments, adjust_pct, fee_pct) VALUES
    ('PIX', 'PIX à vista (3% de desconto)', 'pix', '[{"days": 0, "pct": 100}]', -3, 0),
    ('BOLETO-3X', 'Boleto 30/60/90', 'boleto', '[{"days": 30, "pct": 33.33}, {"days": 60, "pct": 33.33}, {"days": 90, "pct": 33.34}]', 0, 0),
    ('CARTAO-1X', 'Cartão de crédito à vista', 'credit_card', '[{"days": 30, "pct": 100}]', 0, 3.5),
    ('CARTAO-6X', 'Cartão de crédito em 6×', 'credit_card',
     '[{"days": 30, "pct": 16.66}, {"days": 60, "pct": 16.66}, {"days": 90, "pct": 16.67}, {"days": 120, "pct": 16.67}, {"days": 150, "pct": 16.67}, {"days": 180, "pct": 16.67}]', 4, 5.2),
    ('CREDITO-28', 'Crédito direto 28 dias', 'direct_credit', '[{"days": 28, "pct": 100}]', 0, 0)
ON CONFLICT DO NOTHING;
