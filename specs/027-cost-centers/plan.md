# 027 — Plano técnico

## Dados (migração 018_cost_centers.sql)
- `finance.cost_center` (código, nome, pai, tipo, responsável, ativo) com
  `GERAL` semeado; `finance.default_cost_center` (`company` → `GERAL`).
- `finance.account.cost_center_policy` (`required` para receitas e despesas
  lançáveis; `none` para as demais).
- `finance.journal_line.cost_center` + índice; gatilho
  `finance.journal_line_cost_center` (antes de inserir/alterar): aplica a
  política, preenche o padrão (variável de transação `ana.cost_center`,
  definida pelo programa para o documento, ou o da empresa) e recusa centro
  inativo em linha nova.
- `projects.project.cost_center`, `sales.sales_order.cost_center`,
  `inventory.warehouse.cost_center`.
- `finance.cost_center_budget (centro, conta, mês, valor)`.
- `finance.allocation_rule (código, nome, centro de origem, prefixo de
  contas, destinos jsonb)`; o lançamento de rateio tem documento
  `RATEIO-<regra>-<AAAA-MM>` (único: impede repetir o mês).

## Programas
`finance.save_cost_center`, `finance.lookup` (fora do menu),
`finance.post_entry` (manual), `finance.save_budget`,
`finance.save_allocation_rule`, `finance.allocate_costs` (prévia/execução),
`finance.cost_center_report` (resultado gerencial com hierarquia, orçado ×
realizado, gráficos), `finance.trial_balance` com filtro de centro.
Faturamento de vendas e de projetos passam o centro do documento
(`SET LOCAL ana.cost_center`); o cancelamento copia os centros.
