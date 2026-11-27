-- 085 — Currency on purchase and sales orders, and exchange rates as company values (spec 069, T-069-01, RF-069-07).
--
-- A supplier's catalog price may be in dollars or euros (supply.supplier_item.currency); until now the purchase order
-- copied it as if it were in reais. The order now keeps the currency of its prices, the receipt converts at the rate
-- of the day it receives — stock, project costs, journal and bill stay in reais — and keeps the rate it used.
-- The rates are company values with validity (spec 065): "financeiro.cotacao_usd" in force on a date is the number of
-- reais for one dollar. A sale in another currency (an export) is not invoiced yet: the column is there for the
-- projection (spec 069) and stays BRL (T-069-01b).
ALTER TABLE supply.purchase_order ADD COLUMN currency text NOT NULL DEFAULT 'BRL' CHECK (currency ~ '^[A-Z]{3}$');
ALTER TABLE supply.receipt
    ADD COLUMN currency text NOT NULL DEFAULT 'BRL' CHECK (currency ~ '^[A-Z]{3}$'),
    ADD COLUMN exchange_rate numeric(18,6) NOT NULL DEFAULT 1 CHECK (exchange_rate > 0);
ALTER TABLE sales.sales_order ADD COLUMN currency text NOT NULL DEFAULT 'BRL' CHECK (currency = 'BRL');

INSERT INTO ana_system.company_value (name, description, area, value_type, created_by) VALUES
    ('financeiro.cotacao_usd', 'Cotação do dólar: reais por US$ 1, na data (compras em dólar e cenários)', 'financeiro', 'decimal', 'ana'),
    ('financeiro.cotacao_eur', 'Cotação do euro: reais por € 1, na data (compras em euro e cenários)', 'financeiro', 'decimal', 'ana')
ON CONFLICT (name) DO NOTHING;
