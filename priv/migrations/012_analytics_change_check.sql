-- 012 — Analytics refresh only when the sources changed (spec 025, RF-025-01)

CREATE TABLE analytics.refresh_state (
    id           integer PRIMARY KEY CHECK (id = 1),
    signature    numeric NOT NULL,
    refreshed_at timestamptz NOT NULL DEFAULT now()
);

DROP FUNCTION analytics.refresh();

-- Signature: modification counters of the source tables (no writes to read
-- them). A stats reset only causes one extra refresh.
CREATE FUNCTION analytics.refresh(force boolean DEFAULT false) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    sig numeric;
    last numeric;
BEGIN
    IF NOT pg_try_advisory_xact_lock(hashtext('ana.analytics')) THEN
        RETURN 'already_running';
    END IF;
    SELECT COALESCE(sum(n_tup_ins + n_tup_upd + n_tup_del), 0) INTO sig
    FROM pg_stat_user_tables
    WHERE (schemaname, relname) IN (('sales', 'sales_order'), ('sales', 'sales_order_item'),
                                    ('inventory', 'stock_movement'));
    SELECT signature INTO last FROM analytics.refresh_state WHERE id = 1;
    IF NOT force AND current_setting('track_counts')::boolean AND last IS NOT DISTINCT FROM sig THEN
        RETURN 'unchanged';
    END IF;
    REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.daily_sales;
    REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.sales_by_customer;
    REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.stock_balance;
    TRUNCATE analytics.sales_fact;
    INSERT INTO analytics.sales_fact (sale_date, order_number, customer_id, product_id, quantity, amount)
    SELECT o.order_date, o.number, o.customer_id, i.product_id, i.quantity, i.amount
    FROM sales.sales_order o JOIN sales.sales_order_item i ON i.order_id = o.id
    WHERE o.status = 'INVOICED';
    INSERT INTO analytics.refresh_state (id, signature) VALUES (1, sig)
    ON CONFLICT (id) DO UPDATE SET signature = EXCLUDED.signature, refreshed_at = now();
    RETURN 'refreshed';
END $$;
REVOKE EXECUTE ON FUNCTION analytics.refresh(boolean) FROM PUBLIC;
