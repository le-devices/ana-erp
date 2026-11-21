-- 069 — Company values, phase 2 (spec 065): values kept by routines, values in alert rules, the first values of the
-- product kept by its routines.

-- D4: the routines that may keep the value (ana.set_value). A change by a routine is recorded with the routine and
-- the user it ran for (P14), from what to what — never a hidden write.
ALTER TABLE ana_system.company_value ADD COLUMN maintained_by text[] NOT NULL DEFAULT '{}'
    CHECK (array_position(maintained_by, NULL) IS NULL);
ALTER TABLE ana_system.company_value_change ADD COLUMN program text;
ALTER TABLE ana_system.company_value_change DROP CONSTRAINT company_value_change_action_check;
ALTER TABLE ana_system.company_value_change ADD CONSTRAINT company_value_change_action_check
    CHECK (action IN ('defined', 'redefined', 'requested', 'activated', 'approved', 'refused', 'withdrawn', 'archived',
                      'restored', 'kept', 'transported'));

-- T-065-07: an alert rule on a metric may take its limit from a company value ({{valor:nome}}), read at each check.
ALTER TABLE ana_system.alert_rule ADD COLUMN threshold_value text
    CHECK (threshold_value ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,3}$');
DO $$
DECLARE c text;
BEGIN
    SELECT conname INTO c FROM pg_constraint
     WHERE conrelid = 'ana_system.alert_rule'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%threshold IS NOT NULL%';
    EXECUTE format('ALTER TABLE ana_system.alert_rule DROP CONSTRAINT %I', c);
END $$;
ALTER TABLE ana_system.alert_rule ADD CONSTRAINT alert_rule_shape_check
    CHECK (CASE source WHEN 'health' THEN level IS NOT NULL AND op IS NULL AND threshold_value IS NULL
                       ELSE level IS NULL AND op IS NOT NULL AND (threshold IS NOT NULL OR threshold_value IS NOT NULL)
                            AND target <> '*' END);

-- RF-065-07: the first values the product keeps by its routines. The open period moves at each closing; the date of
-- the last physical inventory, at each confirmed count.
UPDATE ana_system.company_value SET maintained_by = ARRAY['finance.close_period']
 WHERE name = 'financeiro.periodo_aberto';
INSERT INTO ana_system.company_value (name, description, area, value_type, created_by, maintained_by)
VALUES ('estoque.ultimo_inventario', 'Data do último inventário físico confirmado', 'estoque', 'date', 'ana',
        ARRAY['inventory.count'])
ON CONFLICT (name) DO NOTHING;

-- RF-065-10: a transport carries the definitions of the values its programs read (and their content, when the value is
-- the same everywhere).
DO $$
DECLARE c text;
BEGIN
    SELECT conname INTO c FROM pg_constraint
     WHERE conrelid = 'ana_system.transport_item'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%''setting''%';
    EXECUTE format('ALTER TABLE ana_system.transport_item DROP CONSTRAINT %I', c);
END $$;
ALTER TABLE ana_system.transport_item ADD CONSTRAINT transport_item_kind_check
    CHECK (kind IN ('program', 'command', 'setting', 'value'));
