-- 075 — Bills of a document found by index (spec 030, flows; P15, P20).
-- The flow sweep checks every waiting step every 30 s; the steps "Cobrança" and "Recebimento" ask for the bills of the
-- document ("ORD-12" and its installments "ORD-12/1", "ORD-12/2"…). "document LIKE $1 || '/%'" with a parameter cannot
-- use an index: each check read the whole finance.bill — with ~1,500 steps waiting and ~15,000 bills, one CPU busy
-- without rest. The base of the document (before the "/") is indexed and found by equality; the LIKE stays as the exact
-- filter, so the answer is the same row for row.
CREATE INDEX IF NOT EXISTS bill_document_base_idx ON finance.bill (split_part(document, '/', 1));

CREATE OR REPLACE FUNCTION flow.document_bills(p_document text) RETURNS SETOF finance.bill
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS
$$ SELECT * FROM finance.bill
    WHERE kind = 'receivable'
      AND (document = p_document OR split_part(document, '/', 1) = split_part(p_document, '/', 1))
      AND (document = p_document OR document LIKE p_document || '/%') $$;
