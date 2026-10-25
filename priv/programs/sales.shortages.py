# ana:description Pedidos com falta: retidos, aguardando compra ou produção e aceitos sem estoque
# ana:category Vendas/Atendimento
"""Spec 041 (RF-041-07). Each order shows what it waits for and the supply linked to it (purchase requests, work
orders, purchases of components); from here one opens the documents, supplies an accepted order or cancels it."""

import datetime

from ana_lib.sales import fulfillment as F

PARAMS = {"situation": {"type": "str", "label": "situação", "empty": "todas",
                        "choices": [["held", "Retidos"], ["supply", "Aguardando compra ou produção"], ["short", "Aceitos com falta"]]}}


def main(situation=None):
    orders = ana.sql(
        "SELECT o.id, o.number, o.order_date, o.fulfillment, p.name AS customer, w.code AS warehouse, "
        "  (SELECT min(i.promised_date) FILTER (WHERE i.promised_date IS NOT NULL) FROM sales.sales_order_item i WHERE i.order_id = o.id) AS promised, "
        "  (SELECT max(i.promised_date) FROM sales.sales_order_item i WHERE i.order_id = o.id) AS last_promised "
        "FROM sales.sales_order o JOIN base.party p ON p.id = o.customer_id JOIN inventory.warehouse w ON w.id = o.warehouse_id "
        "WHERE o.status = 'OPEN' AND o.fulfillment <> 'ok' AND ($1::text IS NULL OR o.fulfillment = $1) ORDER BY o.number LIMIT 1000",
        situation)
    ids = [o["id"] for o in orders]
    reqs = {}
    for r in ana.sql("SELECT DISTINCT l.sales_order_id, r.number, r.status FROM supply.purchase_request_line l "
                     "JOIN supply.purchase_request r ON r.id = l.request_id WHERE l.sales_order_id = ANY($1)", ids):
        reqs.setdefault(r["sales_order_id"], []).append(f"SC {r['number']} ({r['status']})")
    wos = {}
    for r in ana.sql("SELECT sales_order_id, number, status FROM production.work_order WHERE sales_order_id = ANY($1)", ids):
        wos.setdefault(r["sales_order_id"], []).append(f"OP {r['number']} ({r['status']})")
    today = datetime.date.today()
    late = sum(1 for o in orders if o["last_promised"] and o["last_promised"] < today)
    ana.metrics([{"label": "Pedidos com falta", "value": len(orders), "status": "warn" if orders else "ok"},
                 {"label": "Com data prometida vencida", "value": late, "status": "bad" if late else "ok"}], title="Atendimento dos pedidos")
    rows = []
    for o in orders:
        acts = [{"label": "Abrir pedido", "program": "docs.view", "params": {"kind": "order", "key": str(o["number"])}, "open": True}]
        if o["fulfillment"] == "short":
            acts += [{"label": "Comprar o que falta", "program": "sales.supply_order", "params": {"number": o["number"], "kind": "purchase"},
                      "confirm": f"Criar a compra vinculada ao pedido {o['number']}?"},
                     {"label": "Produzir o que falta", "program": "sales.supply_order", "params": {"number": o["number"], "kind": "produce"},
                      "confirm": f"Criar a ordem de produção vinculada ao pedido {o['number']}?"}]
        acts.append({"label": "Cancelar", "program": "sales.cancel_order", "params": {"number": o["number"]}, "open": True})
        rows.append({"pedido": o["number"], "data": o["order_date"], "cliente": o["customer"], "depósito": o["warehouse"],
                     "situação": F.STATUS[o["fulfillment"]],
                     "prometido": o["last_promised"].strftime("%d/%m/%Y") + (" ⚠ vencido" if o["last_promised"] < today else "") if o["last_promised"] else "—",
                     "suprimento": ", ".join(reqs.get(o["id"], []) + wos.get(o["id"], [])) or "—",
                     "_actions": acts, "_open": {"program": "docs.view", "params": {"kind": "order", "key": str(o["number"])}}})
    ana.table(rows, title="Pedidos com falta")
    return {"orders": len(orders), "late": late}
