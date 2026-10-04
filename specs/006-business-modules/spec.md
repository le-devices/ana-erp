# 006 — Módulos de Negócio (núcleo inicial)

## Problema
O ERP precisa de um conjunto mínimo, porém íntegro, de processos de negócio
para demonstrar a plataforma ponta a ponta: cadastros, estoque, vendas e
financeiro com partidas dobradas.

## Esquemas
| Esquema | Tabelas |
|---------|---------|
| `base` | `company`, `party` (cliente/fornecedor), `product` |
| `inventory` | `warehouse`, `stock_movement` |
| `sales` | `sales_order`, `sales_order_item` |
| `finance` | `account` (plano de contas), `journal_entry`, `journal_line`, `bill` |

## Requisitos funcionais
- **RF-006-01** Integridade no banco: chaves estrangeiras, `CHECK` de valores
  positivos, enums por `CHECK`, `NOT NULL` onde aplicável.
- **RF-006-02** Saldo de estoque = soma de movimentos por produto/depósito;
  saída que deixaria saldo negativo é recusada (`INSUFFICIENT_STOCK`).
- **RF-006-03** Pedido: `OPEN` → `INVOICED` | `CANCELLED`. Itens só em
  pedido `OPEN`. Total calculado dos itens.
- **RF-006-04** Faturar pedido (uma Unidade de Trabalho): baixa estoque de cada
  item, cria título a receber, cria lançamento contábil
  (D `customers` / C `sales_revenue`, contas de `finance.default_account`) e muda status para `INVOICED`.
- **RF-006-05** Lançamento contábil só é aceito se soma de débitos = soma de
  créditos (verificado por gatilho de restrição adiada).
- **RF-006-06** Programas entregues (sementes, versão 1):
  | Programa | Exposto | Comando |
  |----------|---------|---------|
  | `base.save_party` | sim | `party` |
  | `base.save_product` | sim | `product` |
  | `inventory.stock_in` | sim | `stockin` |
  | `inventory.balance` | sim | `balance` |
  | `sales.create_order` | sim | `order` |
  | `sales.invoice_order` | sim | `invoice` |
  | `sales.cancel_order` | sim | `cancel` |
  | `finance.trial_balance` | não | `trialbalance` |
  | `analytics.sales_dashboard` | não | `dashboard` |
  | `util.format` (biblioteca) | — | — |
  | `util.validation` (biblioteca) | — | — |
  | `demo.hello` | sim | `hello` |
- **RF-006-07** Dados de demonstração (1 empresa, 3 clientes, 1 fornecedor,
  5 produtos, 2 depósitos, estoque inicial) ficam em `priv/demo/` e só são
  aplicados com `ANA_DEMO=true` (P13: nunca em implantação real por padrão).
- **RF-006-08** Sementes são aplicadas apenas se o programa não existe —
  nunca sobrescrevem alterações feitas no Estúdio.
- **RF-006-09** Listagem de itens (`base.list_products`, comando `products`):
  mercadorias e serviços, com filtros por tipo, situação e texto, mostrando
  preço e — só para mercadorias — saldo total em estoque (serviços nunca têm
  saldo). Itens sem nenhum movimento aparecem com saldo zero.

## Requisitos não funcionais
- **RNF-006-01** (robustez) Concorrência: baixa de estoque trava as linhas
  do produto (`SELECT ... FOR UPDATE` no produto) para impedir saldo negativo
  com faturamentos simultâneos.
- **RNF-006-02** (performance) Índices em todas as FKs; BRIN em datas de
  movimento e lançamento; numeração de pedido por `SEQUENCE`.
- **RNF-006-03** (segurança) `ana_exec` tem DML nos esquemas de negócio mas
  não pode alterar estrutura (sem DDL).

## Critérios de aceite
- **CA-006-01** Criar pedido de 2 itens e faturar: estoque baixa, título
  criado, lançamento balanceado, status `INVOICED`.
- **CA-006-02** Faturar com estoque insuficiente → `INSUFFICIENT_STOCK`,
  nada muda (estoque, título, status).
- **CA-006-03** Inserir lançamento desbalanceado direto via SQL falha no COMMIT.
- **CA-006-04** 10 faturamentos concorrentes do mesmo produto nunca deixam
  saldo negativo.
- **CA-006-05** Um serviço recém-cadastrado e uma mercadoria sem movimento
  aparecem na listagem; o serviço sem saldo, a mercadoria com saldo 0.
