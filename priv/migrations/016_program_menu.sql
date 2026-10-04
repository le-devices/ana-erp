-- 016 — Programs that do not appear as routines in the menu (spec 020 polish)
-- Helpers such as form lookups are executable but are not screens for operators.
ALTER TABLE ana_system.program ADD COLUMN in_menu boolean NOT NULL DEFAULT true;
