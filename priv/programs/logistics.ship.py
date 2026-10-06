# ana:description Expedição de pedido de venda (total ou parcial): separar, embalar e despachar
# ana:exposed yes
# ana:command expedir
"""RF-015-02/03, CA-015-02. Without lines, ships everything still pending of the order. The freight
comes from the carrier's table (customer's state, weight) when not given. Stock leaves at shipment
when logistics.policy.stock_out_on = 'shipment' (otherwise at invoicing, as before). stage: picking
→ packed → shipped (one call can go all the way)."""

import datetime
from decimal import Decimal

from ana_lib.logistics import common

PARAMS = {
    "order": {"type": "int", "required": True, "label": "pedido de venda", "order": 1,
              "lookup": {"program": "logistics.lookup", "params": {"kind": "orders"}}},
    "lines": {"type": "list", "label": "linhas e quantidades (vazio = tudo o que falta)", "order": 2, "columns": {
        "line": {"type": "int", "required": True, "label": "linha do pedido",
                 "lookup": {"program": "sales.lookup", "params": {"kind": "order_lines"}, "depends": ["order"]}},
        "quantity": {"type": "decimal", "required": True, "label": "quantidade a expedir"}}},
    "carrier": {"type": "int", "label": "transportadora", "order": 3, "lookup": {"program": "logistics.lookup", "params": {"kind": "carriers"}}},
    "tracking": {"type": "str", "label": "código de rastreio", "order": 4},
    "packages": {"type": "int", "default": 1, "label": "volumes", "order": 5},
    "weight_kg": {"type": "decimal", "label": "peso (kg)", "order": 6},
    "freight_cost": {"type": "decimal", "label": "frete (custo; vazio = tabela)", "order": 7},
    "freight_charged": {"type": "decimal", "label": "frete cobrado do cliente", "order": 8},
    "expected_date": {"type": "date", "label": "entrega prevista", "order": 9},
    "stage": {"type": "str", "default": "shipped", "label": "até a etapa", "order": 10,
              "choices": [["picking", "Separação"], ["packed", "Embalado"], ["shipped", "Despachado"]]},
}


def main(order, lines=None, carrier=None, tracking=None, packages=1, weight_kg=None, freight_cost=None, freight_charged=None,
         expected_date=None, stage="shipped"):
    o = ana.sql_one("SELECT o.id, o.number, o.status, o.warehouse_id, p.state FROM sales.sales_order o "
                    "JOIN base.party p ON p.id = o.customer_id WHERE o.number = $1 FOR UPDATE OF o", order)
    if not o:
        raise ana.Error("ORDER_NOT_FOUND", f"pedido {order} não encontrado")
    if o["status"] == "CANCELLED":
        raise ana.Error("ORDER_CANCELLED", f"pedido {order} está cancelado")
    pending = {r["line"]: r for r in ana.sql(
        "SELECT i.line, i.product_id, pr.kind, i.quantity - COALESCE(sh.q, 0) AS pending FROM sales.sales_order_item i "
        "JOIN base.product pr ON pr.id = i.product_id "
        "LEFT JOIN (SELECT l.order_line, sum(l.quantity) AS q FROM logistics.shipment_line l JOIN logistics.shipment s "
        "  ON s.id = l.shipment_id WHERE s.sales_order_id = $1 AND s.status NOT IN ('cancelled', 'returned') GROUP BY 1) sh "
        "  ON sh.order_line = i.line WHERE i.order_id = $1 AND pr.kind = 'goods' ORDER BY i.line", o["id"])}
    if lines is None:
        wanted = [(n, r["pending"]) for n, r in pending.items() if r["pending"] > 0]
    else:
        wanted = [(int(l["line"]), Decimal(str(l["quantity"]))) for l in lines]
    wanted = [(n, q) for n, q in wanted if q > 0]
    if not wanted:
        raise ana.Error("NOTHING_TO_SHIP", f"nada a expedir no pedido {order}")
    bad = [n for n, _ in wanted if n not in pending]
    if bad:
        raise ana.Error("LINE_NOT_FOUND", f"linhas sem mercadoria a expedir: {bad}")
    if not carrier:
        # Spec 030: the default carrier lets the flow ship on its own.
        carrier = ana.sql_value("SELECT default_carrier FROM logistics.policy WHERE id = 1")
    if stage == "shipped" and not carrier:
        raise ana.Error("INVALID_PARAMETER", "informe a transportadora para despachar (ou marque uma como padrão)")
    if freight_cost is None and carrier and weight_kg:
        freight_cost = ana.sql_value("SELECT min(price) FROM logistics.freight_rate WHERE carrier_id = $1 AND max_weight_kg >= $2 "
                                     "AND region IN ($3, '*')", carrier, weight_kg, o["state"] or "*")
    s = ana.sql_one("INSERT INTO logistics.shipment (sales_order_id, carrier_id, tracking, packages, weight_kg, freight_cost, "
                    "  freight_charged, expected_date, created_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id, number",
                    o["id"], carrier, tracking, packages, weight_kg, freight_cost, freight_charged, expected_date, ana.context.user)
    ana.sql_batch("INSERT INTO logistics.shipment_line (shipment_id, order_line, product_id, quantity) VALUES ($1, $2, $3, $4)",
                  [[s["id"], n, pending[n]["product_id"], q] for n, q in wanted])
    moved = False
    if stage in ("packed", "shipped"):
        ana.sql_exec("UPDATE logistics.shipment SET status = 'packed' WHERE id = $1", s["id"])
    if stage == "shipped":
        if common.policy()["stock_out_on"] == "shipment":
            need = {}
            for n, q in wanted:
                need[pending[n]["product_id"]] = need.get(pending[n]["product_id"], Decimal(0)) + q
            common.take_stock(o["warehouse_id"], need, f"EXP-{s['number']}")
            moved = True
        ana.sql_exec("UPDATE logistics.shipment SET status = 'shipped', shipped_at = now(), stock_moved = $2, "
                     "expected_date = COALESCE(expected_date, current_date + 3) WHERE id = $1", s["id"], moved)
    state = ana.sql_value("SELECT state FROM logistics.order_shipping WHERE sales_order_id = $1", o["id"])
    labels = {"none": "nada expedido", "partial": "expedido em parte", "full": "totalmente expedido"}
    ana.log(f"expedição {s['number']} do pedido {o['number']}: {labels[state]}")
    return {"shipment": s["number"], "status": stage, "order_state": state, "freight_cost": freight_cost, "stock_moved": moved,
            "shipped_on": datetime.date.today() if stage == "shipped" else None}
