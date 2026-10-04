# 013 — Plano técnico: Cadeia de suprimentos

- Migração `008_supply_chain.sql`: esquema `supply` com `supplier_item`,
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
