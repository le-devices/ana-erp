-- Demo: consulting workflow for the R&D case (spec 021). Applied only with ANA_DEMO=true.

INSERT INTO projects.template (code, name, service_kind, description) VALUES
    ('PD-ELETRONICA', 'P&D em eletrônica embarcada', 'pesquisa e desenvolvimento',
     'Especificação, hardware, firmware, protótipo e validação')
ON CONFLICT DO NOTHING;

INSERT INTO projects.template_item (template_code, code, seq, kind, parent_code, name, profile, planned_hours,
                                    duration_days, predecessors, deliverable) VALUES
    ('PD-ELETRONICA', 'E', 1, 'phase', NULL, 'Especificação', NULL, NULL, NULL, '{}', NULL),
    ('PD-ELETRONICA', 'E.1', 2, 'activity', 'E', 'Requisitos e arquitetura', 'PM', 32, 5, '{}', 'Documento de requisitos'),
    ('PD-ELETRONICA', 'H', 3, 'phase', NULL, 'Hardware', NULL, NULL, NULL, '{}', NULL),
    ('PD-ELETRONICA', 'H.1', 4, 'activity', 'H', 'Esquemático', 'HW-SR', 80, 10, '{E.1}', 'Esquemático revisado'),
    ('PD-ELETRONICA', 'H.2', 5, 'activity', 'H', 'Layout da placa', 'HW', 64, 8, '{H.1}', 'Gerber e lista de materiais'),
    ('PD-ELETRONICA', 'F', 6, 'phase', NULL, 'Firmware', NULL, NULL, NULL, '{}', NULL),
    ('PD-ELETRONICA', 'F.1', 7, 'activity', 'F', 'Firmware base e drivers', 'FW', 120, 15, '{E.1}', 'Firmware v0.1'),
    ('PD-ELETRONICA', 'P', 8, 'phase', NULL, 'Protótipo e validação', NULL, NULL, NULL, '{}', NULL),
    ('PD-ELETRONICA', 'P.1', 9, 'activity', 'P', 'Montagem e testes do protótipo', 'TEC', 40, 5, '{H.2,F.1}', 'Relatório de testes')
ON CONFLICT DO NOTHING;

-- PRJ-001: the tasks of spec 008 organized in phases, with durations and dependencies.
INSERT INTO projects.task (project_id, code, name, kind, seq)
SELECT pr.id, x.code, x.name, 'phase', x.seq
FROM projects.project pr,
     (VALUES ('F1', 'Concepção', 0), ('F2', 'Hardware', 10), ('F3', 'Firmware', 20), ('F4', 'Protótipo', 30))
     AS x(code, name, seq)
WHERE pr.code = 'PRJ-001'
ON CONFLICT DO NOTHING;

UPDATE projects.task t SET parent_id = ph.id, seq = x.seq, duration_days = x.days, profile = x.profile,
                           status = x.status, percent_complete = x.pct,
                           actual_start = CASE WHEN x.status <> 'todo' THEN current_date - 28 END,
                           actual_finish = CASE WHEN x.status = 'done' THEN current_date - 21 END
FROM (VALUES ('1', 'F1', 1, 5, 'PM', 'done', 100),
             ('2', 'F2', 11, 15, 'HW-SR', 'doing', 60),
             ('3', 'F2', 12, 12, 'HW', 'todo', 0),
             ('4', 'F3', 21, 30, 'FW', 'doing', 25),
             ('5', 'F4', 31, 8, 'TEC', 'todo', 0)) AS x(code, phase, seq, days, profile, status, pct),
     projects.project pr, projects.task ph
WHERE pr.code = 'PRJ-001' AND t.project_id = pr.id AND t.code = x.code
  AND ph.project_id = pr.id AND ph.code = x.phase;

INSERT INTO projects.task_dependency (task_id, predecessor_id)
SELECT t.id, p.id
FROM (VALUES ('2', '1'), ('3', '2'), ('4', '1'), ('5', '3'), ('5', '4')) AS d(task, pred),
     projects.project pr, projects.task t, projects.task p
WHERE pr.code = 'PRJ-001' AND t.project_id = pr.id AND t.code = d.task AND p.project_id = pr.id AND p.code = d.pred
ON CONFLICT DO NOTHING;

-- Allocation for the next weeks (people by profile).
INSERT INTO projects.allocation (project_id, task_id, week, employee_id, hours)
SELECT pr.id, t.id, (date_trunc('week', current_date)::date + 7 * w), e.id, x.hours
FROM (VALUES ('2', 'Engenheira de Hardware', 24), ('4', 'Engenheiro de Firmware', 30),
             ('3', 'Engenheira de Hardware', 12)) AS x(task, employee, hours),
     generate_series(0, 3) AS w, projects.project pr, projects.task t, projects.employee e
WHERE pr.code = 'PRJ-001' AND t.project_id = pr.id AND t.code = x.task AND e.name = x.employee
ON CONFLICT DO NOTHING;

INSERT INTO projects.risk (project_id, kind, title, probability, impact, owner, action_plan, client_visible, created_by)
SELECT id, 'risk', 'Prazo de entrega do módulo de rádio pelo fornecedor', 3, 4, 'admin',
       'Cotar segundo fornecedor e antecipar o pedido', true, 'system'
FROM projects.project WHERE code = 'PRJ-001';
