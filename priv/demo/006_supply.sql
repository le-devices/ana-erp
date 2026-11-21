-- Demo: purchasing for the R&D case (spec 013). Applied only with ANA_DEMO=true.
INSERT INTO base.party (kind, name, tax_id, email, city, state) VALUES
    ('supplier', 'Laboratório de Ensaios Delta', '88.888.888/0001-91', 'ensaios@delta.example', 'Campinas', 'SP')
ON CONFLICT DO NOTHING;
INSERT INTO base.product (code, description, unit, price, kind) VALUES
    ('PCB-PROTO', 'Placa de circuito impresso (protótipo, lote de 5)', 'LT', 0, 'goods'),
    ('ENSAIO-EMC', 'Ensaio de compatibilidade eletromagnética', 'UN', 0, 'service')
ON CONFLICT DO NOTHING;

INSERT INTO supply.supplier_item (supplier_id, product_id, supplier_code, price, lead_time_days, min_qty, multiple, preferred)
SELECT s.id, p.id, x.code, x.price, x.lead, x.lot, x.mult, true
FROM (VALUES ('Componentes Eletrônicos Beta', 'MCU-ARM-M4', 'STM-F411', 21.40, 10, 10, 10),
             ('Componentes Eletrônicos Beta', 'SENSOR-IMU', 'IMU-6X', 11.90, 7, 10, 10),
             ('Componentes Eletrônicos Beta', 'MOD-LORA', 'LORA-915', 29.00, 15, 5, 5),
             ('PCB Rápida Ltda', 'PCB-PROTO', 'PROTO-2C', 380.00, 5, 1, 1),
             ('Laboratório de Ensaios Delta', 'ENSAIO-EMC', 'EMC-PRE', 4200.00, 20, 0, 0))
     AS x(supplier, product, code, price, lead, lot, mult)
JOIN base.party s ON s.name = x.supplier JOIN base.product p ON p.code = x.product
ON CONFLICT DO NOTHING;

INSERT INTO supply.replenishment_rule (product_id, warehouse_id, min_qty, safety_qty, max_qty)
SELECT p.id, w.id, x.min, x.safety, x.max
FROM (VALUES ('MCU-ARM-M4', 20, 5, 50), ('SENSOR-IMU', 15, 5, 40), ('MOD-LORA', 10, 2, 25)) AS x(product, min, safety, max)
JOIN base.product p ON p.code = x.product JOIN inventory.warehouse w ON w.code = 'LAB'
ON CONFLICT DO NOTHING;
