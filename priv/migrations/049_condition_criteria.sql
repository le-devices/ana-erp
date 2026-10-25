-- Spec 020 (RF-020-14): a step's condition may have criteria and exceptions — {"any": [[rule]], "except": [rule]} —
-- besides the first format (a list of rules that must all hold). Still a restricted rule, never code.
ALTER TABLE flow.step DROP CONSTRAINT step_condition_check;
ALTER TABLE flow.step ADD CONSTRAINT step_condition_check CHECK (jsonb_typeof(condition) IN ('array', 'object'));
