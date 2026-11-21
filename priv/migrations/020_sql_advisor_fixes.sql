-- 020 — Fixes pointed out by the SQL advisor (spec 019) on the product itself

-- Substring search of items (base.list_products: ILIKE '%text%'). pg_trgm is a trusted
-- extension (the database owner may create it); without it the search still works, only slower.
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
    CREATE INDEX IF NOT EXISTS product_code_trgm_idx ON base.product USING gin (code gin_trgm_ops);
    CREATE INDEX IF NOT EXISTS product_description_trgm_idx ON base.product USING gin (description gin_trgm_ops);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_trgm unavailable (%); item search without trigram index', SQLERRM;
END $$;

-- Foreign key without index (deleting or renaming a user scanned the whole table).
CREATE INDEX IF NOT EXISTS task_run_username_idx ON ana_system.task_run (username);
