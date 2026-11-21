# 038 — Tarefas: processos integrados e conciliação automática

## Fase 1 — fundação
- [x] T-038-01 Migração 037: contas e chaves novas, motivo/custo/valor/lançamento na movimentação, custo médio, regras de contabilização, imutabilidade, revalorização das movimentações existentes (RF-038-01, RNF-038-03/04)
- [x] T-038-02 Gatilho de valorização e contabilização por instrução (RF-038-01, RNF-038-01/02, CA-038-01/02)
- [x] T-038-03 Programas com motivo e custo: compras, venda, expedição, devolução, transferência, peças de OS, materiais de projeto, entrada manual, produção (RF-038-01, CA-038-01)
- [x] T-038-04 Inventário físico, perda/descarte e liberação da quarentena (RF-038-02, CA-038-03)
- [x] T-038-05 Frete: título da transportadora e receita de frete (RF-038-03, CA-038-04)
- [x] T-038-06 Conta de controle do título; `finance.reconciliation()`; tela "Conciliações"; regra de integridade com aviso; ajuste inicial de estoque (RF-038-04, CA-038-05)
- [x] T-038-07 Fechamento de período (RF-038-09, CA-038-11)

## Fase 2 — financeiro
- [x] T-038-08 Baixa exata: residual e tolerância; excedente vira crédito; compensação automática de créditos (RF-038-05, CA-038-06/07)
- [x] T-038-09 Extrato: saldo final, regras de lançamento para linhas sem título, transferência entre contas próprias, conciliação na importação e agendável (RF-038-06, CA-038-08)
- [x] T-038-10 Gateway: conta de valores a receber e casamento do repasse (RF-038-07, CA-038-09)
- [x] T-038-11 Cancelamento das faturas de pedido e de OS (RF-038-08, CA-038-10)

## Fase 3 — compras e projetos
- [x] T-038-12 Nota do fornecedor por confronto, devolução ao fornecedor, despesa de projeto com título (RF-038-10, CA-038-12)
- [x] T-038-13 Apropriação mensal do custo das horas (RF-038-11)
- [x] T-038-14 Marco ligado ao entregável e esteira de projetos (RF-038-12, CA-038-13)

## Fase 4 — rotinas
- [x] T-038-15 Agendamentos prontos do produto (RF-038-13)
