# 021 — Plano técnico

## Princípio
A lógica fica em programas Python dentro do ERP (P5), como na spec 008:
customizável por cliente, depurável e chamável por RPC. A interface ganha
**tipos de saída genéricos** — qualquer programa (do produto ou do cliente)
pode desenhar indicadores, quadro, Gantt, abas e ações — em vez de telas
codificadas para um módulo.

## Dados (migração 013_consulting_projects.sql, esquema `projects`)
- `task` vira a atividade (compatível com 008): `kind` (`phase` |
  `activity`, padrão `activity`), `parent_id` (fase), `seq`,
  `owner_employee_id`, `profile`, `duration_days` (dias úteis),
  `planned_start`, `planned_finish`, `status` (`todo`, `doing`, `review`,
  `done`, `blocked`), `percent_complete`, `actual_start`, `actual_finish`,
  `deliverable`, `acceptance_criteria`, `notes`, `client_visible`. Fases não
  recebem apontamento (gatilho).
- `task_dependency (task_id, predecessor_id, lag_days)` término→início, sem
  ciclos (verificado no programa).
- `template`, `template_item` — modelos por tipo de serviço (P13: dados, não
  código; exemplo só na demonstração).
- `employee.weekly_hours` (padrão 40) e `absence (employee_id, from_date,
  to_date, kind)`; feriados reaproveitam `scheduler.holiday` (um calendário
  só no ERP).
- `allocation (project_id, task_id, week, employee_id | profile, hours)` —
  semana = segunda-feira; uma linha por atividade × pessoa/perfil × semana.
- `baseline (project_id, number, reason, change_id, totals)` e
  `baseline_item (baseline_id, task_id, code, name, kind, planned_hours,
  planned_start, planned_finish, planned_value)` — congeladas.
- `scope_change` (pedido → estimativa → aprovação interna → aprovação do
  cliente | recusa), com efeito no orçamento, marco e nova linha de base.
- `risk` (risco ou pendência; probabilidade e impacto 1–5, dono, plano,
  prazo, situação, visível ao cliente).
- `status_report (project_id, period_start, period_end, content jsonb,
  client_visible, created_by)` — conteúdo já filtrado para o cliente
  (nunca custo nem margem).

## Biblioteca `projects.consulting`
- **Calendário de trabalho**: dias úteis (seg–sex, sem feriados);
  `add_workdays`, `workdays_between`.
- **Cronograma (CPM)**: passada direta e reversa sobre as atividades,
  calculada na leitura (sem gravar nada — P15; 2 mil atividades em
  milissegundos). Previsão: concluída → término real; em andamento → hoje +
  restante (duração × (1 − %)); a fazer → max(início planejado, sucessoras
  das predecessoras + folga, hoje). Folga total = LF − EF; crítica = folga 0.
  Fases = envelope das filhas.
- **Andamento (valor agregado, em horas e em valor)**: BAC = horas
  planejadas (da linha de base mais recente; sem ela, do plano atual);
  VP = BAC × fração do prazo planejado decorrida; VA = BAC × % concluído;
  CR = horas apontadas (não recusadas). IDP = VA/VP, IDC = VA/CR,
  ENT = BAC/IDC. Alerta quando IDC ou IDP < 0,9. Valor monetário usa o
  valor-hora do perfil; custo só para quem gerencia o projeto (RNF-021-02).
- **Capacidade**: capacidade semanal = `weekly_hours` × dias úteis da
  semana (sem feriados e ausências) / 5; soma das alocações da pessoa em
  todos os projetos; sobrealocação gera alerta e sugestão de mover o
  excedente para as semanas seguintes com folga.

## Programas (namespace `projects.`)
`save_template`, `apply_template`, `save_activity`, `update_progress`,
`allocate`, `capacity`, `schedule` (Gantt), `board`, `progress`,
`approve_plan` (linha de base; ativa proposta), `baselines` (comparação),
`scope_change` (ação: request/estimate/approve_internal/approve_customer/
reject), `save_risk`, `status_report` (agendável pela spec 018),
`my_week`, `workspace` (projeto em abas + fluxo guiado), `portfolio`.

## Saídas ricas (runtime + interface)
- Python: `ana.metrics(items)`, `ana.board(columns, cards)`,
  `ana.gantt(items)`, `ana.tabs(items, current)`, `ana.actions(items)`, e
  ações por linha em `ana.table` (chave `_actions`).
- Ação = `{label, program, params, ask?, open?}`: `ask` pede campos num
  formulário em linha e executa o programa ali mesmo (apontar sem sair da
  tela, CA-021-06); `open` navega para a rotina com parâmetros e a executa
  (abas, próximo passo). Depois de uma ação, a rotina atual é reexecutada
  para refletir o novo estado.
- Endereço com parâmetros: `#/ops/<módulo>/<rotina>?project=PRJ-001&view=board`
  preenche o formulário e executa (continuidade, RF-020-12).

## Portal (spec 016)
O relatório de status é gerado, guardado sem custos e marcado como visível
ao cliente; a exibição no portal e a aprovação pelo cliente dependem da
spec 016. Até lá, a aprovação do cliente numa mudança de escopo é
registrada pelo gerente com o nome do aprovador do cliente.

## Finanças do projeto (RF-021-12..15, migração 014_project_financials.sql)
- `rate_profile.standard_cost` (custo-hora padrão do perfil; sem ele, média
  das pessoas ativas do perfil); `planned_expense` (despesas previstas,
  únicas ou mensais, repassáveis com acréscimo); `policy` (linha única:
  margem alvo, mínima, % de despesas gerais); `scenario` (variações salvas);
  `baseline` ganha `projected_revenue`, `projected_cost`,
  `projected_profit`, `low_margin_justification`.
- Biblioteca `projects.finance`: `projection(p, adjustments)` calcula, por
  atividade, horas de pessoal = alocadas (se houver) ou planejadas; custo
  pela pessoa ou pelo perfil; receita pela cobrança; mês a mês pelas semanas
  de alocação (ou pelo cronograma quando não há alocação), marcos pela data
  e despesas mensais em cada mês do prazo. Em execução, soma o realizado ao
  restante (alocações das semanas atuais e futuras). Tudo calculado na
  leitura (P15). Custo e lucro só para gestor/admin (RNF-021-02).
- Programas: `projection` (com simulação imediata e cenários salvos),
  `save_scenario`, `save_planned_expense`, `save_policy` (admin). A aba
  "Viabilidade" entra no projeto, a etapa "Proposta/Aprovação" do fluxo
  guiado sugere avaliar a viabilidade, e `approve_plan` aplica a política.
