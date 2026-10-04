-- 004 — Analytics layer (spec 007)

CREATE SCHEMA IF NOT EXISTS analytics;
REVOKE ALL ON SCHEMA analytics FROM PUBLIC;

-- RF-007-04: columnar fact table when the extension is available.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'citus') THEN
        BEGIN
            CREATE EXTENSION IF NOT EXISTS citus;
            EXECUTE 'CREATE TABLE analytics.sales_fact (
                sale_date date NOT NULL, order_number bigint NOT NULL, customer_id integer NOT NULL,
                product_id integer NOT NULL, quantity numeric(14,3) NOT NULL,
                amount numeric(14,2) NOT NULL) USING columnar';
            RAISE NOTICE 'analytics.sales_fact created with columnar storage';
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'columnar unavailable (%); using a heap table', SQLERRM;
        END;
    END IF;
    IF to_regclass('analytics.sales_fact') IS NULL THEN
        CREATE TABLE analytics.sales_fact (
            sale_date date NOT NULL, order_number bigint NOT NULL, customer_id integer NOT NULL,
            product_id integer NOT NULL, quantity numeric(14,3) NOT NULL,
            amount numeric(14,2) NOT NULL);
        CREATE INDEX sales_fact_date_brin ON analytics.sales_fact USING brin (sale_date);
    END IF;
END $$;
COMMENT ON TABLE analytics.sales_fact IS 'Fato de vendas faturadas (recarregado por analytics.refresh)';

-- RF-007-01, RNF-007-01: materialized views with a unique index.
CREATE MATERIALIZED VIEW analytics.daily_sales AS
SELECT o.order_date AS day, i.product_id, sum(i.quantity) AS quantity, sum(i.amount) AS amount,
       count(DISTINCT o.id) AS orders
FROM sales.sales_order o JOIN sales.sales_order_item i ON i.order_id = o.id
WHERE o.status = 'INVOICED'
GROUP BY o.order_date, i.product_id;
CREATE UNIQUE INDEX daily_sales_uk ON analytics.daily_sales (day, product_id);
COMMENT ON MATERIALIZED VIEW analytics.daily_sales IS 'Vendas faturadas por dia e produto';

CREATE MATERIALIZED VIEW analytics.sales_by_customer AS
SELECT date_trunc('month', o.order_date)::date AS month, o.customer_id, sum(o.total) AS amount,
       count(*) AS orders
FROM sales.sales_order o
WHERE o.status = 'INVOICED'
GROUP BY 1, 2;
CREATE UNIQUE INDEX sales_by_customer_uk ON analytics.sales_by_customer (month, customer_id);
COMMENT ON MATERIALIZED VIEW analytics.sales_by_customer IS 'Vendas faturadas por mês e cliente';

CREATE MATERIALIZED VIEW analytics.stock_balance AS
SELECT m.product_id, m.warehouse_id, sum(m.quantity) AS balance, max(m.created_at) AS last_movement
FROM inventory.stock_movement m
GROUP BY 1, 2;
CREATE UNIQUE INDEX stock_balance_uk ON analytics.stock_balance (product_id, warehouse_id);
COMMENT ON MATERIALIZED VIEW analytics.stock_balance IS 'Saldo de estoque por produto e depósito';

-- RF-007-02, RNF-007-02
CREATE FUNCTION analytics.refresh() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    IF NOT pg_try_advisory_xact_lock(hashtext('ana.analytics')) THEN
        RETURN 'already_running';
    END IF;
    REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.daily_sales;
    REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.sales_by_customer;
    REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.stock_balance;
    TRUNCATE analytics.sales_fact;
    INSERT INTO analytics.sales_fact (sale_date, order_number, customer_id, product_id, quantity, amount)
    SELECT o.order_date, o.number, o.customer_id, i.product_id, i.quantity, i.amount
    FROM sales.sales_order o JOIN sales.sales_order_item i ON i.order_id = o.id
    WHERE o.status = 'INVOICED';
    RETURN 'refreshed';
END $$;
REVOKE EXECUTE ON FUNCTION analytics.refresh() FROM PUBLIC;

-- RNF-007-03
GRANT USAGE ON SCHEMA analytics TO ana_exec, ana_read;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO ana_exec, ana_read;
