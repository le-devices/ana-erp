-- 086 — The projection (spec 069, T-069-02, D1, D4).
--
-- "# ana:read_only yes" in a program's header: its run is a read-only transaction — the database refuses any write,
-- whatever the code does (a projection never saves, spec 069 D4; like an indicator, spec 048).
ALTER TABLE ana_system.program ADD COLUMN read_only boolean NOT NULL DEFAULT false;

-- The day of the month the taxes of what was invoiced are paid (the projection puts them there).
INSERT INTO ana_system.company_value (name, description, area, value_type, created_by)
VALUES ('financeiro.dia_impostos', 'Dia do mês em que os impostos do faturamento do mês anterior são recolhidos', 'financeiro',
        'integer', 'ana')
ON CONFLICT (name) DO NOTHING;
INSERT INTO ana_system.company_value_version (name, valid_from, content, requested_by)
SELECT 'financeiro.dia_impostos', DATE '2000-01-01', '20'::jsonb, 'ana'
WHERE NOT EXISTS (SELECT 1 FROM ana_system.company_value_version WHERE name = 'financeiro.dia_impostos');
