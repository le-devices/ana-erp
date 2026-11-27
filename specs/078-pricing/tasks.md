# 078 — Tarefas

Antes do código: plan.md com o modelo de dados (esquema, componente, regra, tabela), como o mecanismo de escolha e as fórmulas da spec 049 são reaproveitados sem duplicar, o cache em memória e as medições alvo.

## Fase 1 — venda
- [ ] T-078-01 Modelo de dados: esquemas, componentes, regras de preço com vigência e critérios; grupo de acesso "preços" (RF-078-02..04, D9)
- [ ] T-078-02 Serviço `pricing.engine` / `pricing.calculate`: escolha pela especificidade da 049, fórmulas fechadas, explicação, cache por versão (RF-078-01, RNF-078-01, RNF-078-04)
- [ ] T-078-03 Tabelas de preço em grade, importação/exportação, "copiar com nova vigência", reajuste em lote ensaiado com quatro olhos (RF-078-05, CA-078-05)
- [ ] T-078-04 Casos de teste de preço e "qual preço vale?" (RF-078-06, CA-078-01, CA-078-03)
- [ ] T-078-05 Pedido de venda e fatura pelo serviço: preço automático, esquema explicado, limites por papel com aprovação, margem mínima, registro do cálculo (RF-078-07, RF-078-08, CA-078-02, CA-078-04, CA-078-07)
- [ ] T-078-06 Acréscimo financeiro da condição de pagamento como componente; contabilização por papéis (RF-078-10, CA-078-08)

## Fase 2 — compra
- [ ] T-078-07 Preço líquido e custo efetivo da compra; custo no estoque e nos cenários; conferência da nota do fornecedor (RF-078-09, CA-078-06)

## Fase 3 — campanhas e integrações
- [ ] T-078-08 Campanhas e comissão como componente (RF-078-11)
- [ ] T-078-09 Choques "preço de venda" e "desconto" nos cenários; oráculo de preço no uso simulado; "por que este preço?" no assistente (RF-078-10)
- [ ] T-078-10 Desempenho medido na bateria (RNF-078-01) e auditoria de experiência (spec 050)
