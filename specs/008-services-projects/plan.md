# 008 — Plano técnico: Serviços e Projetos

## Migração `005_services_projects.sql`
- `base.product.kind` (`goods` default | `service`).
- `finance.default_account(key PK, account FK, description)`, sementes:
  `customers`→1.1.2, `sales_revenue`→4.1.1, `service_revenue`→4.1.2 (nova),
  `service_tax_withheld`→1.1.4 (nova, "Imposto sobre serviços retido a
  compensar"). Função `finance.account_for(key)` (STABLE) — erro claro se a
  chave faltar.
- Esquema `projects`:
  | Tabela | Notas |
  |--------|-------|
  | `rate_profile` | `code` PK, `hourly_rate` |
  | `employee` | `hourly_cost`, `username` único opcional |
  | `project` | `code` único, `manager`, `billing`, `status`, orçamento, `service_tax_rate`, `service_tax_withheld` |
  | `project_rate` | (project, profile) → `hourly_rate` |
  | `task` | (project, code) único |
  | `project_member` | (project, employee) PK, perfil de cobrança |
  | `time_entry` | `status`, valores congelados, `invoice_id` |
  | `expense` | `stock_movement_id`, `rebillable`, `markup_pct`, `status`, `invoice_id` |
  | `milestone` | `status`, `invoice_id` |
  | `invoice`, `invoice_line` | numeração por sequência; `bill_id`, `entry_id`, `reversal_entry_id` |
- Gatilhos (RNF-008-01):
  - `time_entry`: `BEFORE UPDATE/DELETE` impede alterar linhas `approved`/
    `invoiced`, exceto as transições do faturamento (`approved→invoiced`,
    `invoiced→approved` no cancelamento); limite diário de 24 h por
    colaborador (`BEFORE INSERT/UPDATE`, serializado por advisory lock).
  - `expense` e `milestone`: imutáveis quando faturados.
- Índices: `time_entry(project_id, status)`, `time_entry(employee_id, entry_date)`,
  BRIN em datas; `expense(project_id, status)`; `milestone(project_id, status)`;
  todas as FKs indexadas.
- Grants no padrão; `ana_read` não lê `hourly_cost` (privilégio por coluna).

## Confidencialidade (RNF-008-02)
Programas recebem `ana.context.user` e `ana.context.role`. Biblioteca
`projects.access` com `can_manage(project)` (gestor ou `admin`) usada para
aprovar, ver custo e faturar. O extrato não seleciona colunas de custo.

## Programas
| Programa | Exposto | Comando |
|----------|---------|---------|
| `projects.access` (biblioteca) | — | — |
| `projects.save_profile` | sim | `profile` |
| `projects.save_employee` | sim | `employee` |
| `projects.save_project` (inclui tarefas, equipe e valores) | sim | `project` |
| `projects.log_time` | sim | `logtime` |
| `projects.delete_time_entry` | sim | — |
| `projects.approve_time` | sim | `approve` |
| `projects.post_expense` | sim | `expense` |
| `projects.save_milestone` / `projects.complete_milestone` | sim | `milestone` |
| `projects.invoice_project` | sim | `invoiceproject` |
| `projects.cancel_invoice` | sim | `cancelinvoice` |
| `projects.dashboard` | não | `projects` |
| `projects.time_report` | sim | `timereport` |

## Faturamento (RF-008-12)
1. `SELECT ... FROM projects.project WHERE id = $1 FOR UPDATE` (RNF-008-03).
2. Horas: `approved`, faturáveis, `invoice_id IS NULL`, `entry_date <= through`,
   agrupadas por perfil e valor-hora → linhas.
3. Despesas `posted` refaturáveis não faturadas →
   `round(qty × unit_cost × (1 + markup/100), 2)`.
4. Marcos `completed` não faturados.
5. Total; imposto = round(total × alíquota, 2); título = total − imposto se retido.
6. Lançamento: D `customers` (líquido) + D `service_tax_withheld` (se retido) /
   C `service_revenue` (total).
7. Atualiza origens com `invoice_id` e estado faturado.

## Decisões
- Despesa entra direto como `posted` (quem lança é o gestor).
- Custos ainda não geram lançamento contábil (depende de contas a pagar —
  próxima etapa); aparecem no painel gerencial.
