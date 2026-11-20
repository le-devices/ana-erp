-- 066 — Universal rehearsal (spec 056): any routine that writes can be rehearsed. The transaction runs whole and is
-- undone at the end; the effect is read from the rows the transaction itself left, never from code of each routine.

-- What the business calls each table and, for documents, the viewer that opens them (spec 035). Data, not code:
-- a company adds its own tables here (P21 spirit — names and links are data).
CREATE TABLE ana_system.business_table (
    table_name  text PRIMARY KEY CHECK (table_name ~ '^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$'),
    label       text NOT NULL CHECK (length(btrim(label)) BETWEEN 2 AND 80),
    doc_kind    text,                                           -- docs.view "kind"; the key is the row's id
    show_order  int NOT NULL DEFAULT 100
);
COMMENT ON TABLE ana_system.business_table IS 'Nome de negócio das tabelas e o documento que abre cada linha (ensaio, spec 056)';

INSERT INTO ana_system.business_table (table_name, label, doc_kind, show_order) VALUES
    ('sales.sales_order',            'Pedidos de venda',            'order',            10),
    ('sales.sales_order_item',       'Itens de pedido',             NULL,               11),
    ('field.service_order',          'Ordens de serviço',           'service_order',    12),
    ('projects.invoice',             'Faturas de projeto',          'project_invoice',  13),
    ('projects.invoice_line',        'Linhas de fatura de projeto', NULL,               14),
    ('projects.milestone',           'Marcos de projeto',           'milestone',        15),
    ('finance.bill',                 'Títulos (contas a receber e a pagar)', 'bill',    20),
    ('finance.charge',               'Cobranças',                   NULL,               21),
    ('finance.journal_entry',        'Lançamentos contábeis',       'entry',            22),
    ('finance.journal_line',         'Linhas de lançamento',        NULL,               23),
    ('finance.bank_statement_line',  'Linhas de extrato',           'statement_line',   24),
    ('supply.purchase_request',      'Solicitações de compra',      'purchase_request', 30),
    ('supply.purchase_order',        'Ordens de compra',            'purchase_order',   31),
    ('supply.receipt',               'Recebimentos de compra',      'receipt',          32),
    ('supply.supplier_invoice',      'Notas de fornecedor',         'supplier_invoice', 33),
    ('production.work_order',        'Ordens de produção',          'work_order',       40),
    ('logistics.shipment',           'Expedições',                  'shipment',         41),
    ('logistics.transfer',           'Transferências',              'transfer',         42),
    ('inventory.stock_movement',     'Movimentos de estoque',       NULL,               43),
    ('integration.outbox',           'Mensagens de saída (e-mails e envios)', NULL,     50),
    ('tax.calculation',              'Cálculos de impostos',        NULL,               60);

-- Read by the core only (programs never read ana_system, P10).

-- The rows written by the CURRENT transaction (its subtransactions included: savepoints, nested programs) that are
-- still there: visible rows whose xmin is a transaction in progress can only be ours, because rows of other
-- transactions in progress are invisible. Read as the owner so the summary also shows what the routine wrote
-- through the database's own functions (e-mail outbox); only rows this transaction wrote, never anything else.
-- System tables are refused and columns that look like secrets are dropped.
CREATE FUNCTION ana_system.rehearsal_rows(p_table regclass, p_limit int)
RETURNS TABLE (total bigint, sample jsonb) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE
    v_schema text;
    v_top    bigint := pg_current_xact_id()::text::bigint;
    v_low    bigint := v_top & 4294967295;
    v_epoch  bigint := v_top >> 32;
    v_where  text;
BEGIN
    SELECT n.nspname INTO v_schema FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = p_table;
    IF v_schema IS NULL OR v_schema IN ('ana_system', 'pg_catalog', 'information_schema', 'pg_toast') THEN
        RAISE EXCEPTION 'REHEARSAL_TABLE: tabela fora do ensaio' USING ERRCODE = 'insufficient_privilege';
    END IF;
    -- xmin >= our own xid first (cheap), then the status (ours, in progress, not an aborted savepoint).
    v_where := format('t.xmin::text::bigint >= %s AND pg_xact_status(((%s::bigint << 32) | t.xmin::text::bigint)::text::xid8) = ''in progress''',
                      v_low, v_epoch);
    EXECUTE format('SELECT count(*) FROM %s t WHERE %s', p_table, v_where) INTO total;
    EXECUTE format('SELECT coalesce(jsonb_agg(j), ''[]'') FROM (SELECT to_jsonb(t) - ARRAY(SELECT k FROM jsonb_object_keys(to_jsonb(t)) k '
                   'WHERE k ~* ''(password|secret|token|hash|private|credential)'') AS j FROM %s t WHERE %s LIMIT %s) s',
                   p_table, v_where, greatest(0, least(p_limit, 20))) INTO sample;
    RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION ana_system.rehearsal_rows(regclass, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ana_system.rehearsal_rows(regclass, int) TO ana_exec;

-- The audit tells a rehearsal from a real run (nothing of it was kept).
ALTER TABLE ana_system.execution ADD COLUMN rehearsal boolean NOT NULL DEFAULT false;

-- Catalog (RF-056-03): which routines write — by themselves, or through the library functions, programs and
-- database functions they use — so the forms offer "Ensaiar" exactly there. Filled by the inspection when a program
-- is saved or the product refreshed: "writing" = its functions that write ("*" = module-level code); "uses" = edges
-- "function>library:function", "function>program" and "function>db:schema.function".
ALTER TABLE ana_system.program ADD COLUMN writing text[] NOT NULL DEFAULT '{}';
ALTER TABLE ana_system.program ADD COLUMN uses text[] NOT NULL DEFAULT '{}';

-- The routines that write, following the edges until nothing new is found.
CREATE FUNCTION ana_system.writing_programs() RETURNS SETOF text LANGUAGE sql STABLE
SET search_path = pg_catalog AS $$
    WITH RECURSIVE edge AS (
        SELECT p.name, p.kind, split_part(u, '>', 1) AS src, split_part(u, '>', 2) AS dst
          FROM ana_system.program p, unnest(p.uses) u
    ), w(ref) AS (
        SELECT ref FROM (
            SELECT p.name AS ref FROM ana_system.program p WHERE p.kind = 'program' AND cardinality(p.writing) > 0
            UNION
            SELECT p.name || ':' || f FROM ana_system.program p, unnest(p.writing) f WHERE p.kind = 'library'
            UNION
            SELECT 'db:' || n.nspname || '.' || f.proname FROM pg_proc f JOIN pg_namespace n ON n.oid = f.pronamespace
             WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND f.provolatile = 'v'
               AND f.prosrc ~* '\m(insert\s+into|update\s+\S+\s+set|delete\s+from|merge\s+into)'
        ) seed
        UNION
        SELECT CASE WHEN e.kind = 'library' THEN e.name || ':' || e.src ELSE e.name END
          FROM edge e JOIN w ON w.ref = e.dst
    )
    SELECT ref FROM w WHERE position(':' IN ref) = 0
$$;
