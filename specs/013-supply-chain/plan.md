# 013 — Plano técnico: Cadeia de suprimentos

- Migração `019_supply_chain.sql`: esquema `supply` com `supplier_item`,
  `purchase_request`, `purchase_request_line`, `approval_limit`,
  `purchase_order`, `purchase_order_line`, `receipt`, `receipt_line`,
  `replenishment_rule`; visão `supply.on_order` (pedido − recebido por item e
  depósito); contas padrão `inventory`, `suppliers`, `purchased_services`.
- Gatilhos: transições de estado válidas; quantidade recebida ≤ tolerância.
- Reservas: visão `inventory.reserved` (pedidos de venda abertos + ordens de
  produção liberadas + ordens de serviço agendadas) usada também pelas specs
  014 e 015.
- Programas: `supply.save_supplier_item`, `supply.request_purchase`,
  `supply.approve_request`, `supply.create_orders`, `supply.receive`,
  `supply.suggest_replenishment`, `supply.supplier_performance`,
  `supply.confirm_delivery_date` (exposto).

## Decisões de implementação (out/2026)
- Centro de custo (spec 027) em solicitações e linhas de ordem: projeto →
  depósito → padrão da empresa; o recebimento lança nesse centro.
- Compra **para projeto** (mercadoria ou serviço) não entra no estoque: vai
  direto para `project_costs` (5.1.3, centro do projeto) e vira despesa do
  projeto (spec 008: `component` ou `subcontract`, refaturável quando
  indicado). Mercadoria sem projeto entra no estoque (`inventory`); serviço
  sem projeto → `purchased_services` (5.1.2). Evita custo em dobro, já que a
  despesa de projeto (spec 008) não gera lançamento.
- Alçada: `supply.approval_limit_of(usuário, papel)` (SECURITY DEFINER, lê os
  grupos de acesso) — maior limite entre papel e grupos; nulo = sem limite.
- Reservado (`inventory.reserved`) hoje = pedidos de venda abertos; ordens de
  produção (014) e de serviço (015) entram na visão quando existirem.
- Tolerância de recebimento e prazos em `supply.policy` (P13); alçadas em
  `supply.approval_limit` (o produto traz só `admin` sem limite).
- Bancada `supply.workbench` (comando `compras`): solicitações a aprovar,
  aprovadas a comprar, ordens a receber — com ações na própria tela.
