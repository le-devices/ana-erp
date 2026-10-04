-- Demo: projection inputs for PRJ-001 (spec 021, RF-021-12..15). Applied only with ANA_DEMO=true.
UPDATE projects.rate_profile SET standard_cost = x.cost
FROM (VALUES ('PM', 110), ('HW-SR', 120), ('HW', 85), ('FW', 95), ('TEC', 45)) AS x(code, cost)
WHERE rate_profile.code = x.code AND rate_profile.standard_cost IS NULL;

UPDATE projects.policy SET overhead_pct = 15 WHERE id = 1;

INSERT INTO projects.planned_expense (project_id, description, kind, amount, monthly, expected_date, rebillable,
                                      markup_pct, created_by)
SELECT id, x.description, x.kind, x.amount, x.monthly, current_date + x.days, x.rebillable, x.markup, 'system'
FROM projects.project,
     (VALUES ('Componentes e PCBs do protótipo', 'pcb', 6500, false, 20, true, 10),
             ('Licença de ferramenta de CAD (mensal)', 'software', 900, true, 0, false, 0)) AS
     x(description, kind, amount, monthly, days, rebillable, markup)
WHERE code = 'PRJ-001';
