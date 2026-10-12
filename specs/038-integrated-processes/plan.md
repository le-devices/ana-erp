# 038 — Plano técnico: processos integrados e conciliação automática

## Visão
```
 programa (venda, compra, OS, projeto, produção, contagem…)
   └─ INSERT inventory.stock_movement (motivo, custo quando conhecido)
        └─ gatilho por instrução (tabela de transição), no banco:
             1. trava inventory.item_cost na ordem do item
             2. custo médio ponderado móvel → custo unitário e valor de cada linha
             3. um lançamento por documento × motivo, pela inventory.posting_rule
             4. grava o entry_id nas linhas
 finance.reconciliation()  ← tela "Conciliações" e verificação periódica (integridade)
 finance.period_close      ← gatilho recusa lançamento em mês fechado
```
A contabilização do estoque fica no banco (P4): nenhum caminho, nem SQL
direto, cria movimentação valorizada sem o lançamento. Os programas só dizem
o **motivo** e, em entradas com custo próprio, o **custo unitário**.

## Dados (migração 037)
- **Contas novas**, com as chaves de `default_account` entre parênteses:

  | Conta | Descrição | Chave |
  |---|---|---|
  | 2.1.3 | Recebimentos a faturar | `goods_received` |
  | 3.1.2 | Saldos de abertura | `opening_balances` |
  | 4.1.3 | Receita de frete | `freight_revenue` |
  | 4.3.1 | Ganhos de estoque | `inventory_gains` |
  | 5.1.4 | Fretes sobre vendas | `freight_expense` |
  | 5.3.2 | Variação de produção | `production_variance` |
  | 5.4.1 | Perdas de estoque | `inventory_losses` |

  A conta 5.1.1, que já existe, recebe a chave `cogs`.
- **`inventory.stock_movement`** ganha quatro colunas:
  - `reason`, um dos motivos: `purchase`, `sale`, `service_part`,
    `project_material`, `customer_return`, `adjustment_in`, `adjustment_out`,
    `loss`, `scrap`, `production_issue`, `production_receipt`, `transfer`,
    `opening`;
  - `unit_cost numeric(18,6)`;
  - `value numeric(14,2)`;
  - `entry_id`.

  A linha valorizada é imutável: produto, depósito, quantidade, custo e
  valor não mudam depois de gravados, e nada é apagado.
- **`inventory.item_cost`**: `product_id`, `quantity`, `value`, `avg_cost`.
  É o estoque próprio: transferências não o alteram, porque a mercadoria em
  trânsito continua sendo da empresa.
- **`inventory.posting_rule`**: motivo, chave de débito e chave de crédito.
  Chave nula significa "sem lançamento". O cliente pode ajustar (P13).
- **`finance.bill.account`**: conta de controle do título, preenchida nos
  títulos existentes e por padrão nos novos (a receber → clientes; a pagar →
  fornecedores; a devolução informa créditos de clientes).
- **`finance.period_close`**: histórico de `closed_until`, com quem fechou e
  quando; reabrir insere uma data menor. O gatilho em `journal_entry` recusa
  lançamentos com data menor ou igual à data fechada.
- **`logistics.shipment.freight_bill_id`**: título da transportadora.

## Regras de custo (gatilho)
- **Entrada com `unit_cost` informado** (compra a preço do pedido, entrega de
  produção ao custo padrão): o valor do item passa a ser o valor atual mais
  a quantidade vezes o custo, e a média é recalculada.
- **Entrada sem custo** (devolução, ajuste): usa a média vigente. Sem média,
  usa o custo padrão do item, depois o preço do fornecedor, depois zero.
- **Saída**: usa a média vigente. A saída que zera o item leva o valor
  restante inteiro, para não deixar resíduo de arredondamento.
- **Transferência**: registra custo e valor só para consulta; não altera o
  `item_cost` nem lança.
- **Motivo ausente**, como em programa de cliente antigo: vira
  `adjustment_in` ou `adjustment_out` conforme o sinal (RNF-038-04).

## Programas alterados (fase 1)
| Programa | Motivo | Mudança |
|---|---|---|
| `supply.receive` | `purchase` (custo = preço) | a perna de estoque passa a ser "recebimentos a faturar" × fornecedores; o banco lança estoque × recebimentos a faturar |
| `sales.invoice_order` | `sale` | centro de custo definido antes da baixa; frete cobrado em receita de frete |
| `logistics.ship` | `sale` | título da transportadora (frete) |
| `logistics.deliver` (devolvida) | `customer_return` | — |
| `logistics.transfer` | `transfer` | — |
| `logistics.register_return` | `customer_return` | título com conta de créditos de clientes |
| `field.use_part` | `service_part` ou `project_material` (OS de projeto) | — |
| `projects.post_expense` (item) | `project_material` | custo da despesa = custo do estoque |
| `inventory.stock_in` | `adjustment_in` (custo opcional) | — |
| `production.issue_components` | `production_issue` | não lança mais por conta própria |
| `production.deliver` | `production_receipt` (custo padrão unitário) | — |
| `production.close_order` | — | custo real com componentes pelo valor requisitado; sem projeto, lança só a variação (variação × em elaboração) |

## Programas novos (fase 1)
- `inventory.count`: contagem por depósito, com ajustes valorizados
  (documento INV-n).
- `inventory.write_off`: perda ou descarte.
- `inventory.release_quarantine`: libera para um depósito ou descarta.
- `finance.reconciliations`: tela "Conciliações", com detalhamento.
- `finance.close_period`: fechar ou reabrir mês; só administrador; auditado.
- `finance.inventory_opening_adjustment`: ajuste inicial, uma vez e auditado.

## Conciliação
`finance.reconciliation()` devolve `key`, `label`, saldo auxiliar, saldo
contábil e diferença para:
- cada conta de controle de títulos (clientes, fornecedores, créditos de
  clientes);
- estoque: Σ `item_cost.value` × conta de estoque;
- recebimentos a faturar: compras sem título × conta;
- em elaboração: ordens abertas × conta;
- documentos sem lançamento: títulos, recebimentos, movimentações
  valorizadas e fretes sem título.

O `ana_checks` (categoria integridade) ganha a regra
`ledger_reconciliation`: uma diferença maior que R$ 0,01 vira achado
crítico com aviso; o achado se resolve sozinho quando a diferença volta a
zero.

## Riscos
- **Revalorização inicial em base grande:** um laço por item em ordem de id;
  base de cliente com milhões de linhas leva minutos. A migração roda uma vez
  e informa o tempo.
- **Arredondamento:** valor por linha com 2 casas e média com 6; a saída que
  zera o item absorve o resíduo.
