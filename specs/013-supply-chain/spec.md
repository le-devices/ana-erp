# 013 — Cadeia de suprimentos (compras, fornecedores, reposição)

## Problema
Comprar bem é comprar o necessário, do fornecedor certo, a tempo. Isso vale
para mercadorias (componentes, PCBs, insumos) e para **serviços contratados**
(montagem terceirizada, ensaios em laboratório, certificação, transporte).
Hoje o ANA não tem compras: só entradas manuais de estoque e despesas de
projeto.

## Histórias
- **H1** Como comprador, mantenho o catálogo de fornecimento: quem fornece cada
  item (mercadoria ou serviço), código no fornecedor, preço, prazo de entrega,
  lote mínimo e fornecedor preferencial.
- **H2** Como requisitante (engenharia, produção, almoxarifado, projeto), peço
  compras; como aprovador, aprovo ou recuso dentro da minha alçada.
- **H3** Como comprador, transformo pedidos aprovados em ordens de compra por
  fornecedor e acompanho prazos.
- **H4** Como almoxarife, recebo mercadorias (entrada no estoque, parcial ou
  total); como requisitante, dou o **aceite** de serviços prestados.
- **H5** Como financeiro, o recebimento gera o título a pagar e o lançamento.
- **H6** Como planejador, o ANA sugere reposição: ponto de pedido, estoque de
  segurança, estoque máximo, considerando saldo, pedidos em aberto, reservas e
  consumo médio.
- **H7** Como gestor, vejo desempenho de fornecedores (pontualidade, prazo
  real, divergências).
- **H8** Como gestor de projeto, compras ligadas a um projeto viram despesa do
  projeto no recebimento (spec 008), refaturável quando indicado.

## Requisitos funcionais
- **RF-013-01** Fornecimento (`supply.supplier_item`): fornecedor, item, código
  no fornecedor, preço unitário, moeda, prazo (dias), lote mínimo e múltiplo,
  preferencial, validade do preço.
- **RF-013-02** Solicitação de compra (`supply.purchase_request`): itens,
  quantidades, data necessária, motivo, projeto opcional, origem (`manual`,
  `replenishment`, `planning`, `project`). Estados: `draft` → `submitted` →
  `approved` | `rejected` → `ordered` | `cancelled`.
- **RF-013-03** Alçadas de aprovação por valor (`supply.approval_limit`: papel
  ou grupo → valor máximo); acima da alçada, exige aprovador com limite maior.
  Quem solicita não aprova a própria solicitação.
- **RF-013-04** Ordem de compra (`supply.purchase_order`): fornecedor, linhas
  (com origem na solicitação), preço, prazo prometido, condições de pagamento.
  Estados: `draft` → `sent` → `partially_received` → `received` | `cancelled`.
  Gerar ordens a partir de solicitações aprovadas agrupando por fornecedor
  preferencial.
- **RF-013-05** Recebimento (`supply.receipt`): por linha, quantidade recebida
  (parcial permitido, tolerância configurável); mercadoria → movimento de
  entrada no depósito; serviço → aceite com observação; linha ligada a projeto
  → despesa do projeto (spec 008).
- **RF-013-06** Contabilização no recebimento: D estoque (mercadoria) ou D
  despesa/custo de serviços (serviço) ou D custo do projeto / C fornecedores;
  título a pagar com vencimento pelas condições. Contas via
  `finance.default_account` (`inventory`, `suppliers`, `purchased_services`).
- **RF-013-07** Parâmetros de reposição por item e depósito
  (`supply.replenishment_rule`): estoque mínimo (ponto de pedido), segurança,
  máximo, método (`min_max` | `average_consumption`), janela de consumo.
- **RF-013-08** Sugestão de reposição (`supply.suggest_replenishment`):
  disponível projetado = saldo + em pedido − reservado (pedidos de venda abertos,
  ordens de produção, ordens de serviço); abaixo do ponto → sugestão até o
  máximo, respeitando lote mínimo/múltiplo e prazo do fornecedor preferencial;
  gera solicitações `replenishment` (com confirmação).
- **RF-013-09** Desempenho de fornecedor: pontualidade (% linhas no prazo),
  prazo médio real × prometido, divergência de quantidade e preço.
- **RF-013-10** Programas expostos para integração (ex.: portal de fornecedor
  confirmar prazo de entrega da ordem).

## Requisitos não funcionais
- **RNF-013-01** (integridade) Estados e quantidades garantidos no banco:
  recebido ≤ pedido × (1 + tolerância); ordem recebida/cancelada imutável.
- **RNF-013-02** (robustez) Recebimento é uma Unidade de Trabalho: estoque,
  título, lançamento e despesa de projeto juntos ou nada.
- **RNF-013-03** (performance) Sugestão de reposição calculada em consultas
  agregadas por conjunto (não item a item); índices por item/depósito/estado.
- **RNF-013-04** (P13) Alçadas, tolerâncias, contas e condições são parâmetros.

## Critérios de aceite
- **CA-013-01** Solicitação de 10 MCUs aprovada vira ordem do fornecedor
  preferencial com o preço do catálogo.
- **CA-013-02** Solicitante não aprova a própria solicitação; valor acima da
  alçada exige aprovador com limite maior.
- **CA-013-03** Recebimento parcial de 6 de 10: ordem `partially_received`,
  estoque +6, título a pagar de 6 × preço, lançamento balanceado.
- **CA-013-04** Aceite de serviço (ensaio de laboratório) ligado a projeto vira
  despesa do projeto, sem movimento de estoque.
- **CA-013-05** Item com ponto de pedido 20, saldo 5, em pedido 0, máximo 50 e
  lote múltiplo 10 → sugestão de 50 (arredondada ao múltiplo).
- **CA-013-06** Receber acima da tolerância é recusado pelo banco.
