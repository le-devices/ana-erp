-- Demo: cost centers for the R&D case (spec 027). Applied only with ANA_DEMO=true.
INSERT INTO finance.cost_center (code, name, parent_code, kind) VALUES
    ('OPER', 'Operações', NULL, 'operational'),
    ('ENG', 'Engenharia (P&D)', 'OPER', 'operational'),
    ('LAB', 'Laboratório e protótipos', 'OPER', 'operational'),
    ('COM', 'Comercial', NULL, 'commercial'),
    ('ADM', 'Administrativo', NULL, 'administrative')
ON CONFLICT DO NOTHING;
UPDATE projects.project SET cost_center = 'ENG' WHERE code = 'PRJ-001' AND cost_center IS NULL;
UPDATE inventory.warehouse SET cost_center = 'COM' WHERE code = 'CENTRAL' AND cost_center IS NULL;
UPDATE inventory.warehouse SET cost_center = 'LAB' WHERE code = 'LAB' AND cost_center IS NULL;
INSERT INTO finance.allocation_rule (code, name, source, account_prefix, targets) VALUES
    ('ADM-OPER', 'Rateio do administrativo', 'ADM', '5', '[{"cost_center": "ENG", "pct": 60}, {"cost_center": "COM", "pct": 40}]')
ON CONFLICT DO NOTHING;
