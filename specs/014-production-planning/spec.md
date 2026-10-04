# 014 — Planejamento de produção e de capacidade (bens e serviços)

## Problema
Quem fabrica (inclusive lotes de protótipos) precisa saber **o que**, **quanto**
e **quando** produzir e comprar, e se há **capacidade** — de máquinas, bancadas
e pessoas. Quem presta serviços tem o mesmo problema com horas de equipe: os
projetos e ordens de serviço disputam os mesmos engenheiros e técnicos.

## Histórias
- **H1** Como engenheiro de produto, cadastro a **estrutura** de um item
  (componentes, quantidades, perda %), em vários níveis, com versões.
- **H2** Como engenheiro de processos, cadastro o **roteiro** (operações em
  sequência: recurso, preparação, tempo por unidade).
- **H3** Como planejador, mantenho **recursos** (bancada, máquina, linha, perfil
  de pessoas) com calendário de capacidade (horas/dia, eficiência, exceções).
- **H4** Como planejador, rodo o **planejamento de necessidades**: a partir da
  demanda (pedidos de venda, previsão, estoque mínimo, ordens de serviço,
  marcos de protótipo de projetos) o ANA explode estruturas, desconta saldos e
  ordens em andamento e propõe ordens de produção e solicitações de compra com
  datas deslocadas pelos prazos.
- **H5** Como planejador, vejo a **carga × capacidade** por recurso e semana e
  ajusto datas quando houver sobrecarga.
- **H6** Como supervisor, libero ordens de produção, requisito componentes
  (baixa de estoque), apontamos operações (tempo real) e entrego o produto
  acabado (entrada no estoque) com custo apurado.
- **H7** Como gestor de serviços (caso P&D), vejo a demanda de horas por perfil
  e semana (tarefas planejadas de projetos + ordens de serviço) contra a
  capacidade da equipe, e quem está sobrecarregado.
- **H8** Como gestor de projeto, uma ordem de produção de protótipos pode ser
  ligada a um projeto: o custo vai para o projeto (spec 008).

## Requisitos funcionais
- **RF-014-01** Estrutura (`production.structure`, `structure_line`): item pai,
  versão, vigência, componente, quantidade por unidade, perda %, fantasma
  (sub-montagem não estocada). Detecção de ciclos.
- **RF-014-02** Roteiro (`production.routing`, `operation`): sequência, recurso,
  preparação (min), tempo por unidade (min), operações de serviço (ex.: teste
  funcional por técnico — recurso do tipo `people` ligado a perfil de 008).
- **RF-014-03** Recursos (`production.resource`): tipo `machine` | `bench` |
  `line` | `people`, capacidade diária (h), eficiência %, calendário de
  exceções (feriados, manutenção, férias); para `people`, perfil de cobrança
  e/ou colaboradores.
- **RF-014-04** Previsão de demanda (`production.forecast`): item, período,
  quantidade; consumida pelos pedidos reais no mesmo período.
- **RF-014-05** Planejamento de necessidades (`production.plan`): horizonte,
  balde (dia/semana), itens; resultado gravado em `planning_run`/`suggestion`
  (produzir/comprar, item, quantidade, data de início e necessidade, origem
  rastreável até a demanda). Lote: mínimo, múltiplo, lote-a-lote. Aprovar
  sugestões gera ordens de produção e solicitações de compra (spec 013).
- **RF-014-06** Ordem de produção (`production.order`): item, quantidade,
  versão de estrutura/roteiro, datas, projeto opcional. Estados `planned` →
  `released` → `in_progress` → `completed` → `closed` | `cancelled`.
  Liberação reserva componentes; requisição baixa estoque; apontamento
  registra operação/tempo/quantidade boa e refugo; entrega dá entrada do
  acabado; encerramento apura custo (componentes + horas × custo do recurso) e
  variação contra o padrão.
- **RF-014-07** Carga × capacidade por recurso e balde, com ordens planejadas e
  liberadas; sinaliza sobrecarga (> 100 %) e sugere data mais cedo possível
  (capacidade finita simples, por prioridade e data).
- **RF-014-08** Capacidade de serviços: demanda = horas planejadas de tarefas
  de projetos distribuídas no período + ordens de serviço agendadas (spec 015);
  capacidade = colaboradores × horas/dia × eficiência − ausências; relatório por
  perfil e por colaborador.
- **RF-014-09** Ordem de produção ligada a projeto lança o custo apurado como
  despesa do projeto (refaturável conforme o projeto).

## Requisitos não funcionais
- **RNF-014-01** (performance) Explosão de estruturas em SQL recursivo e
  cálculo por nível em conjunto; 10 mil itens × 5 níveis em < 30 s.
- **RNF-014-02** (robustez) Planejamento roda em segundo plano, é idempotente
  (substitui o resultado anterior do mesmo cenário) e nunca altera ordens
  firmes sem aprovação.
- **RNF-014-03** (integridade) Ciclos de estrutura recusados no banco;
  requisição ≤ reservado + tolerância; custo apurado imutável após encerrar.

## Critérios de aceite
- **CA-014-01** Placa com 2 níveis (placa → módulo → componentes): demanda de
  10 placas gera ordens para módulo e placa e solicitações de compra dos
  componentes faltantes, com datas deslocadas pelos prazos.
- **CA-014-02** Estrutura com ciclo é recusada.
- **CA-014-03** Ordem de 10 unidades: requisição baixa componentes; entrega de
  9 boas e 1 refugo; custo apurado = componentes + horas × custo/h.
- **CA-014-04** Recurso com 8 h/dia e carga de 50 h na semana aparece com
  125 % e data sugerida posterior.
- **CA-014-05** Engenheira de firmware com 3 projetos somando 52 h na semana
  aparece sobrecarregada no relatório de capacidade de serviços.
- **CA-014-06** Ordem de protótipos ligada ao projeto lança o custo como
  despesa do projeto.
