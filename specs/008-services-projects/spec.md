# 008 — Serviços e Projetos

## Problema
Empresas de serviços técnicos — o caso de partida é **P&D em eletrônica e
software embarcado** — vendem **horas de equipe** e, às vezes, **protótipos**
(componentes, placas, montagem). Precisam saber, por projeto: quanto foi
orçado, quanto foi gasto (horas × custo + materiais), quanto foi faturado e
qual a margem. Hoje o ANA só fatura mercadorias com baixa de estoque.

## Escopo desta etapa
Projetos, equipe e perfis com valor-hora, tarefas, apontamento e aprovação de
horas, despesas e materiais de protótipo (inclusive consumo de estoque),
marcos de valor fixo, fatura de serviço (horas + despesas refaturáveis +
marcos) com título a receber, lançamento contábil e imposto sobre serviços (ex.: ISS) informativo, e painel
orçado × realizado. Também: item do tipo **`service`** (sem estoque) e contas
contábeis **parametrizáveis** (P13).

Fora do escopo (próximas etapas): NFS-e, retenções federais, contas a pagar
integradas a compras, rateio de custos indiretos, apontamento por cronômetro.

## Histórias
- **H1** Como gestor comercial, cadastro um projeto para um cliente com forma de
  cobrança (por hora, preço fechado ou misto), orçamento em horas e valor,
  gestor responsável e tabela de valor-hora por perfil.
- **H2** Como engenheiro, apontar minhas horas do dia por tarefa — no Estúdio ou
  por programa exposto (ex.: integração com ferramenta de controle de tarefas).
- **H3** Como gestor do projeto, aprovo ou rejeito horas; ao aprovar, valor-hora
  e custo-hora ficam congelados (reajustes futuros não mudam o passado).
- **H4** Como gestor, lanço despesas do projeto (componentes, PCBs, serviços de
  terceiros, viagens), indicando se são refaturáveis e com qual acréscimo;
  componentes do estoque são consumidos do depósito.
- **H5** Como gestor, registro marcos de valor fixo (ex.: "Protótipo v1
  montado e testado") e os concluo.
- **H6** Como financeiro, faturo o projeto até uma data: o ANA reúne horas
  aprovadas, despesas refaturáveis e marcos concluídos ainda não faturados.
- **H7** Como diretor, vejo orçado × realizado e margem por projeto.
- **H8** Como cliente final, recebo um extrato de horas por período.

## Requisitos funcionais
- **RF-008-01** Item (`base.product`) tem `kind` `goods` | `service`.
  Faturamento de pedido só baixa estoque de `goods`.
- **RF-008-02** Contas contábeis usadas pelos programas vêm de
  `finance.default_account(key → account)` (`customers`, `sales_revenue`,
  `service_revenue`, `service_tax_withheld`, ...), editável por cliente; função
  `finance.account_for(key)`.
- **RF-008-03** Colaborador (`projects.employee`): nome, `username` ANA
  (opcional, para apontar), perfil padrão, `hourly_cost` (confidencial — ver
  RNF-008-02), ativo.
- **RF-008-04** Perfil (`projects.rate_profile`): código, descrição,
  `hourly_rate` padrão de venda.
- **RF-008-05** Projeto (`projects.project`): código único, nome, cliente,
  `manager` (username), `billing` `hourly` | `fixed` | `mixed`, `status`
  `proposal` → `active` → `suspended` | `closed`, datas, orçamento de horas e
  de valor, alíquota do imposto sobre serviços (`service_tax_rate`, ex. ISS) e
  se ele é retido pelo tomador (`service_tax_withheld`). Valor-hora por perfil
  pode ser sobrescrito no projeto (`projects.project_rate`).
- **RF-008-06** Tarefas (`projects.task`: código, nome, horas previstas,
  faturável). Equipe (`projects.project_member`): colaborador + perfil de
  cobrança.
- **RF-008-07** Apontamento (`projects.time_entry`): colaborador, projeto,
  tarefa, data, horas (0 < h ≤ 24, múltiplos de 0,25), descrição obrigatória,
  faturável (herda da tarefa). Só membros da equipe, em projeto `active`, sem
  data futura. Soma diária por colaborador ≤ 24 h. O colaborador só aponta
  para si mesmo, salvo gestor do projeto ou `admin`.
- **RF-008-08** Estados: `pending` → `approved` | `rejected`;
  `approved` → `invoiced`. Pendentes e rejeitados podem ser editados/excluídos
  pelo autor; aprovados e faturados são imutáveis (garantido no banco).
- **RF-008-09** Aprovação (gestor do projeto ou `admin`) congela `hourly_rate`
  (projeto → perfil) e `hourly_cost` (colaborador). Rejeição exige motivo.
- **RF-008-10** Despesa (`projects.expense`): `kind` (`component`, `pcb`,
  `supplies`, `subcontract`, `travel`, `other`), descrição, fornecedor
  opcional, quantidade, custo unitário, `rebillable`, `markup_pct`;
  opcionalmente produto + depósito → movimento de saída de estoque com
  documento `PRJ-<code>`.
- **RF-008-11** Marco (`projects.milestone`): descrição, valor, data prevista;
  `planned` → `completed` → `invoiced`.
- **RF-008-12** Faturar projeto até uma data (uma Unidade de Trabalho): cria
  `projects.invoice` numerada com itens agrupados (horas por perfil, despesas
  refaturáveis com acréscimo, marcos concluídos), marca as origens como
  faturadas, cria `finance.bill` a receber (valor líquido do imposto retido,
  quando houver) e lançamento contábil balanceado (D `customers`
  [+ D `service_tax_withheld`] / C `service_revenue`). Sem itens →
  `NOTHING_TO_INVOICE`.
- **RF-008-13** Cancelar fatura (título ainda em aberto): lançamento de
  estorno, título cancelado, origens devolvidas ao estado anterior.
- **RF-008-14** Painel por projeto: horas previstas × apontadas × aprovadas,
  custo (horas aprovadas × custo + despesas), faturado, a faturar, margem,
  consumo do orçamento (%).
- **RF-008-15** Extrato de horas por projeto e período (para o cliente): data,
  colaborador, perfil, tarefa, horas, descrição — **sem** custo.

## Requisitos não funcionais
- **RNF-008-01** (integridade) Regras de estado e imutabilidade no banco
  (gatilhos), não só nos programas — vale para qualquer programa futuro ou
  customização do cliente.
- **RNF-008-02** (segurança) Custo-hora e margem só aparecem para gestor do
  projeto ou admin; o extrato do cliente nunca contém custo.
- **RNF-008-03** (robustez) Faturamento concorrente do mesmo projeto não
  duplica cobrança (trava do projeto `FOR UPDATE`).
- **RNF-008-04** (performance) Índices por projeto/estado/data; painel
  calculado em uma consulta agregada por projeto.
- **RNF-008-05** (P13) Nenhuma conta, alíquota ou valor fixo no código dos
  programas: tudo em parâmetros ou cadastros.

## Critérios de aceite
- **CA-008-01** Pedido com item `service` sem saldo fatura normalmente;
  `goods` continua exigindo saldo.
- **CA-008-02** Apontar 9 h + 16 h no mesmo dia para o mesmo colaborador → a
  segunda falha com `DAILY_LIMIT`.
- **CA-008-03** Não membro da equipe → `NOT_A_MEMBER`; projeto não ativo →
  `PROJECT_INACTIVE`; data futura → `INVALID_DATE`.
- **CA-008-04** Aprovar congela valor-hora; mudar o valor-hora depois não
  altera o apontamento aprovado. `UPDATE` direto em apontamento aprovado
  falha no banco.
- **CA-008-05** Despesa de componente com produto consome estoque
  (`PRJ-<code>`); sem saldo → `INSUFFICIENT_STOCK`.
- **CA-008-06** Faturar projeto com 10 h aprovadas a R$ 200,00, despesa
  refaturável de R$ 100,00 com 20 % e marco de R$ 5.000,00 → fatura de
  R$ 7.120,00; título e lançamento balanceado; origens faturadas; segundo
  faturamento → `NOTHING_TO_INVOICE`.
- **CA-008-07** Imposto sobre serviços retido de 5 % → título de R$ 6.764,00 e lançamento com
  ISS retido.
- **CA-008-08** Cancelar a fatura devolve horas a `approved`, despesas e
  marcos ao estado anterior, e o balancete volta ao valor anterior.
- **CA-008-09** Usuário que não é gestor não aprova horas (`FORBIDDEN`) e não vê
  custo no painel.
- **CA-008-10** Dois faturamentos simultâneos do mesmo projeto geram uma única
  fatura.

## Perguntas em aberto (para o caso de partida)
1. Arredondamento de horas: frações de 15 min estão bem, ou outra regra?
2. Horas extras/noturnas/fim de semana têm valor diferenciado para o cliente?
3. Protótipo: normalmente preço fechado (marco) ou custo + acréscimo?
4. Regime tributário e município (define ISS, retenções e NFS-e da próxima etapa).
5. Projetos com financiamento (ex.: incentivos a P&D) exigem relatórios
   específicos de horas por pesquisador e atividade?
