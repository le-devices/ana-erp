# 015 — Plano técnico: Logística e serviços em campo

## Dados (migração `026_logistics_field.sql`)
- `logistics.policy`: `stock_out_on` (`invoice` | `shipment`); depósitos
  `TRANSITO` (transferências) e `QUARENTENA` (devoluções a inspecionar).
- `logistics.carrier`, `freight_rate` (região = UF ou `*`, peso até, preço;
  vale a mais barata que atende).
- `logistics.transfer` / `transfer_line` (`draft` → `shipped` → `received`;
  divergência = enviado − recebido, registrada).
- `logistics.shipment` / `shipment_line` (`picking` → `packed` → `shipped`
  → `delivered` | `returned`); gatilho: expedido por linha ≤ pedido.
  Visão `logistics.order_shipping` (nada, parcial, total).
- `logistics.customer_return` / `return_line`: entrada no depósito ou na
  quarentena, crédito ao cliente (D `sales_returns` / C `customer_credits` +
  título a pagar ao cliente).
- `field.sla_policy` (horas por prioridade) e `customer_sla` (contrato);
  `field.technician` (colaborador da spec 008 + depósito do veículo/maleta);
  `field.service_order` (`open` → `scheduled` → `en_route` → `in_progress`
  → `done` → `invoiced` | `cancelled`; `due_at` = abertura + SLA).
- `field.assignment` com **`EXCLUDE USING gist (employee_id WITH =, period
  WITH &&)`** (RNF-015-01) e gatilho de ausências; `seq` e `distance_km` para
  a rota.
- `field.work_log`, `part_usage`, `checklist_answer` com `client_key`
  único (idempotência do app em campo, RNF-015-02); `checklist_template`;
  `sign_off`; `invoice_line`.
- `inventory.reserved` desconta o já expedido quando a baixa é na expedição.

## Faturamento
- OS avulsa: horas de trabalho × valor-hora do perfil do técnico,
  deslocamento (horas × valor do deslocamento + km × valor por km, da
  política) e peças × preço → título e lançamento (D clientes / C receita de
  serviços e de vendas), documento `OS-n`.
- OS de projeto: horas viram apontamentos aprovados na atividade indicada e
  peças/deslocamento viram despesas refaturáveis do projeto (o projeto fatura).

## Programas
Logística: `transfer`, `ship` (cria, embala e despacha numa chamada, ou passo
a passo), `deliver`, `register_return`, `save_carrier`, `freight_quote`,
`shipping_workbench` (comando `expedicao`). Campo: `save_technician`,
`open_order` (exposta e de portal: o cliente abre chamado), `schedule`,
`agenda`, `route`, `start_trip`, `log_work`, `use_part`, `checklist`,
`sign_off`, `invoice_orders`, `sla_report`, `workbench` (comando `campo`).
