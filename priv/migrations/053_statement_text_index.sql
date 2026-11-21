-- Spec 042 (E-01): matching a charge id inside the text of the open statement lines must not cost lines × charges.
-- A trigram index over the open lines' text lets each charge be one index lookup (pg_trgm, migration 020).
DO $$
BEGIN
    CREATE INDEX IF NOT EXISTS bank_statement_line_open_text_trgm ON finance.bank_statement_line
        USING gin (lower(description || ' ' || COALESCE(document, '')) gin_trgm_ops) WHERE status = 'open';
EXCEPTION WHEN undefined_object THEN
    RAISE NOTICE 'pg_trgm unavailable (%); charge matching without trigram index', SQLERRM;
END $$;
