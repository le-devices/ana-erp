-- T-030-06b: the receipt (sales, field) and payment (purchase) stages reconcile the document in the statement
-- (finance.reconcile_document) instead of only waiting. Only stages left as shipped are changed: a stage the
-- company configured stays as it is.
UPDATE flow.step SET mode = 'auto', program = 'finance.reconcile_document',
       params = jsonb_build_object('flow', flow_code, 'key', '{{key}}')
 WHERE (flow_code, code) IN (('sales', 'receipt'), ('field', 'receipt'), ('purchase', 'payment'))
   AND mode = 'wait' AND program IS NULL;
