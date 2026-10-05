# 014 — Plano técnico: Planejamento de produção e capacidade

## Dados (migração `025_production.sql`, esquema `production`)
- `item_plan` (por item: fazer/comprar, prazo em dias, lote mínimo e múltiplo,
  estoque de segurança, depósito, custo padrão).
- `structure` (item pai, versão, vigência, ativa) e `structure_line`
  (componente, quantidade por unidade, perda %, fantasma); **gatilho de
  ciclo** (CTE recursiva sobre as estruturas ativas) — CA-014-02.
- `resource` (tipo `machine` | `bench` | `line` | `people`, h/dia,
  eficiência %, custo/h, perfil de cobrança para `people`) e
  `resource_calendar` (exceções por dia: horas disponíveis).
- `routing` (item, versão, ativa) e `operation` (sequência, recurso,
  preparação min, min/unidade).
- `forecast` (item, semana, quantidade).
- `planning_run` (cenário, horizonte, balde, situação, totais) e
  `suggestion` (produzir/comprar, item, quantidade, início, necessidade,
  origem rastreável, situação).
- `order` (número, item, quantidade, versões, depósito, datas, prioridade,
  projeto, situação, quantidades boa/refugo, custos padrão/real/variação),
  `order_component`, `order_operation`, `operation_report`.
- `policy` (tolerância de requisição %); contas padrão `work_in_process`
  (1.1.5), `production_absorbed` (5.3.1); a visão `inventory.reserved`
  passa a somar as reservas das ordens liberadas.

## Custos e lançamentos
- Custo do componente = custo padrão do item (`item_plan.standard_cost`), ou
  preço do fornecedor preferencial (spec 013), ou zero.
- Requisição: saída do estoque, D `work_in_process` / C `inventory`.
- Apontamento: horas × custo/h do recurso, D `work_in_process` / C
  `production_absorbed`.
- Encerramento: custo real (imutável) = componentes + horas; D `inventory`
  (ou `project_costs` e despesa do projeto, quando ligada a projeto —
  RF-014-09) / C `work_in_process`; variação = real − padrão (quantidade
  planejada × custo padrão de componentes e operações), gravada.
- Entrega: entrada do acabado bom no estoque (ordem de projeto não entra no
  estoque: vai para o projeto).

## Planejamento de necessidades (`production.plan`)
- Nível baixo de cada item por CTE recursiva; processa nível a nível em
  lote (poucas consultas por nível, cálculo em memória).
- Demanda independente: itens de pedidos de venda abertos, previsão líquida
  (previsão − pedidos da mesma semana), estoque de segurança.
- Oferta: saldo, ordens de produção abertas (quantidade − entregue), ordens
  de compra em aberto (spec 013).
- Líquido por balde (semana) → lote (mínimo/múltiplo) → início = necessidade
  − prazo; explosão das ordens sugeridas para os componentes (com perda e
  fantasmas atravessados).
- Idempotente por cenário: substitui as sugestões abertas do cenário;
  nunca toca ordens firmes. Pode rodar em segundo plano (execução assíncrona
  ou agendamento, spec 018).
- Aprovar: produzir → ordem `planned`; comprar → solicitação de compra
  (origem `planning`, spec 013).

## Capacidade
- Carga × capacidade por recurso e semana: operações das ordens planejadas,
  liberadas e em andamento na semana de início; capacidade = h/dia × dias
  úteis (feriados do agendamento, exceções do recurso) × eficiência;
  > 100 % sinalizado; data sugerida por capacidade finita simples
  (prioridade, data).
- Serviços: alocação semanal por colaborador (spec 021) contra a capacidade
  da semana (horas semanais, feriados, ausências); por perfil, inclui a
  alocação ainda sem pessoa.

## Programas
`production.save_item_plan`, `production.save_structure`,
`production.save_resource`, `production.save_routing`,
`production.save_forecast`, `production.plan`,
`production.approve_suggestions`, `production.create_order`,
`production.release_order`, `production.issue_components`,
`production.report_operation`, `production.deliver`,
`production.close_order`, `production.capacity_load`,
`production.service_capacity`, `production.workbench` (comando `producao`),
`production.lookup`.
