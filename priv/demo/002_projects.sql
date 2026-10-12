-- Demo: R&D services in electronics and embedded software (spec 008, T-008-09).
-- Applied only with ANA_DEMO=true.

INSERT INTO base.party (kind, name, tax_id, email, city, state) VALUES
    ('customer', 'Indústria de Sensores Alfa S.A.', '55.555.555/0001-55', 'engenharia@alfa.example', 'São José dos Campos', 'SP'),
    ('supplier', 'Componentes Eletrônicos Beta', '66.666.666/0001-66', 'vendas@beta.example', 'São Paulo', 'SP'),
    ('supplier', 'PCB Rápida Ltda', '77.777.777/0001-77', 'orcamento@pcbrapida.example', 'Joinville', 'SC')
ON CONFLICT DO NOTHING;

INSERT INTO base.product (code, description, unit, price, kind) VALUES
    ('HORA-ENG', 'Hora de engenharia', 'H', 0, 'service'),
    ('MCU-ARM-M4', 'Microcontrolador ARM Cortex-M4', 'UN', 32.00, 'goods'),
    ('SENSOR-IMU', 'Sensor inercial 6 eixos', 'UN', 18.50, 'goods'),
    ('MOD-LORA', 'Módulo de rádio LoRa', 'UN', 45.00, 'goods')
ON CONFLICT DO NOTHING;

INSERT INTO inventory.warehouse (code, description) VALUES ('LAB', 'Almoxarifado do laboratório')
ON CONFLICT DO NOTHING;

-- Spec 038: opening balance at an estimated cost (60 % of the price); the database posts it against opening balances.
INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, created_by, reason, unit_cost)
SELECT p.id, w.id, q.qty, 'in', 'OPENING-BALANCE', 'system', 'opening', round(p.price * 0.6, 2)
FROM (VALUES ('MCU-ARM-M4', 50), ('SENSOR-IMU', 40), ('MOD-LORA', 20)) AS q(product, qty)
JOIN base.product p ON p.code = q.product
JOIN inventory.warehouse w ON w.code = 'LAB';

INSERT INTO projects.rate_profile (code, description, hourly_rate) VALUES
    ('PM', 'Gestão de projeto', 240.00),
    ('HW-SR', 'Engenharia de hardware sênior', 260.00),
    ('HW', 'Engenharia de hardware', 200.00),
    ('FW', 'Firmware embarcado', 220.00),
    ('TEC', 'Técnico de montagem e testes', 120.00)
ON CONFLICT DO NOTHING;

INSERT INTO projects.employee (name, username, profile, hourly_cost) VALUES
    ('Administrador', 'admin', 'PM', 110.00),
    ('Engenheira de Hardware', NULL, 'HW-SR', 120.00),
    ('Engenheiro de Firmware', NULL, 'FW', 95.00),
    ('Técnico de Laboratório', NULL, 'TEC', 45.00)
ON CONFLICT DO NOTHING;

INSERT INTO projects.project (code, name, customer_id, manager, billing, status, start_date,
                              due_date, budget_hours, budget_amount, service_tax_rate, description)
SELECT 'PRJ-001', 'Módulo de telemetria IoT — hardware e firmware', p.id, 'admin', 'mixed', 'active',
       current_date - 30, current_date + 90, 600, 140000, 0.05,
       'Projeto e prototipagem de módulo de telemetria com rádio LoRa e sensor inercial'
FROM base.party p WHERE p.tax_id = '55.555.555/0001-55'
ON CONFLICT DO NOTHING;

INSERT INTO projects.task (project_id, code, name, planned_hours, billable)
SELECT pr.id, t.code, t.name, t.hours, t.billable
FROM projects.project pr,
     (VALUES ('1', 'Requisitos e arquitetura', 40, true),
             ('2', 'Esquemático', 120, true),
             ('3', 'Layout da placa', 100, true),
             ('4', 'Firmware', 260, true),
             ('5', 'Montagem e testes do protótipo', 80, true),
             ('9', 'Reuniões internas', 0, false)) AS t(code, name, hours, billable)
WHERE pr.code = 'PRJ-001'
ON CONFLICT DO NOTHING;

INSERT INTO projects.project_member (project_id, employee_id, profile)
SELECT pr.id, e.id, e.profile FROM projects.project pr, projects.employee e
WHERE pr.code = 'PRJ-001'
ON CONFLICT DO NOTHING;

INSERT INTO projects.milestone (project_id, description, amount, due_date)
SELECT id, 'Protótipo v1 (5 unidades montadas e testadas)', 18000.00, current_date + 45
FROM projects.project WHERE code = 'PRJ-001';
