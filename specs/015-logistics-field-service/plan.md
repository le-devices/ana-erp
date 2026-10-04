# 015 — Plano técnico: Logística e serviços em campo

- Migração `010_logistics.sql`: esquemas `logistics` (`carrier`,
  `freight_rate`, `transfer`, `transfer_line`, `shipment`, `shipment_line`,
  `return`, `return_line`) e `field` (`service_order`, `assignment`,
  `work_log`, `part_usage`, `checklist_template`, `checklist_answer`,
  `sign_off`, `route_stop`); depósito de trânsito; extensão `btree_gist` para
  `EXCLUDE USING gist (employee_id WITH =, period WITH &&)` na agenda.
- Parâmetro `stock_out_on` (`invoice` | `shipment`).
- Programas: `logistics.transfer_*`, `logistics.ship`, `logistics.deliver`,
  `logistics.register_return`, `field.open_order`, `field.schedule`,
  `field.route`, `field.log_work`, `field.use_part`, `field.sign_off`,
  `field.invoice_orders`, `field.sla_report`.
