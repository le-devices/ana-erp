-- 084 — Change watch (spec 068), part 7: "Avisar quando mudar" offered from usage (T-068-11, RF-068-09).
-- Whoever opens the history of the same record again and again is offered a rule that tells them when it changes
-- (spec 051, D3): one more kind of suggestion, read from the executions already logged — nothing written per opening.
ALTER TABLE automation.suggestion DROP CONSTRAINT suggestion_kind_check;
ALTER TABLE automation.suggestion ADD CONSTRAINT suggestion_kind_check CHECK (kind IN ('schedule', 'variant', 'routine', 'watch'));
