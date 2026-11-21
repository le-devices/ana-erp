-- Spec 042 (A-01, A-03): a step that depends on a physical fact or on a choice the flow cannot make is never
-- automatic — receiving goods (they must arrive) and scheduling a technician (someone chooses who). The
-- configuration refuses "automatic" for them and the engine treats an old automatic setting as manual.
ALTER TABLE flow.step ADD COLUMN auto_allowed boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN flow.step.auto_allowed IS 'false: a etapa só roda por uma pessoa (fato físico ou escolha que a esteira não faz)';
UPDATE flow.step SET auto_allowed = false WHERE (flow_code, code) IN (('purchase', 'receive'), ('field', 'schedule'));
UPDATE flow.step SET mode = 'manual' WHERE NOT auto_allowed AND mode = 'auto';
ALTER TABLE flow.step ADD CONSTRAINT step_auto_allowed_check CHECK (auto_allowed OR mode <> 'auto');
