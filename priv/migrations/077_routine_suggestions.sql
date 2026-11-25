-- 077 — Automation audit (spec 051, T-051-06): the product's own routines are created off; when people still run
-- their program by hand, the administrators are offered to turn the routine on (suggestion kind "routine").
ALTER TABLE automation.suggestion DROP CONSTRAINT suggestion_kind_check;
ALTER TABLE automation.suggestion ADD CONSTRAINT suggestion_kind_check CHECK (kind IN ('schedule', 'variant', 'routine'));
