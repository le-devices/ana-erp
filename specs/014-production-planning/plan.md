# 014 — Plano técnico: Planejamento de produção e capacidade

- Migração `009_production.sql`: esquema `production` (`structure`,
  `structure_line`, `routing`, `operation`, `resource`, `resource_calendar`,
  `forecast`, `planning_run`, `suggestion`, `order`, `order_component`,
  `order_operation_report`); gatilho de ciclo (CTE recursiva); contas padrão
  `work_in_process`, `finished_goods`, `production_variance`.
- Explosão: `WITH RECURSIVE` com nível baixo (low-level code) calculado na
  gravação da estrutura, para planejar nível a nível em lote.
- Planejamento em execução assíncrona (`async`), com prazo maior via perfil de
  limite (spec 012).
- Programas: `production.save_structure`, `production.save_routing`,
  `production.save_resource`, `production.plan`, `production.approve_suggestions`,
  `production.release_order`, `production.issue_components`,
  `production.report_operation`, `production.complete_order`,
  `production.close_order`, `production.capacity_load`,
  `production.service_capacity`.
