# ana:description Aprova sugestões do planejamento: gera ordens de produção e solicitações de compra
# ana:exposed yes
"""RF-014-05. "make" → planned production order; "buy" → purchase request (origin planning,
spec 013), one per need week and warehouse. Without ids, every open suggestion of the scenario."""

import datetime

PARAMS = {
    "scenario": {"type": "str", "default": "principal", "label": "cenário"},
    "ids": {"type": "list", "label": "sugestões (vazio = todas as abertas)"},
    "warehouse": {"type": "str", "default": "CENTRAL", "label": "depósito das compras"},
}


def main(scenario="principal", ids=None, warehouse="CENTRAL"):
    rows = ana.sql("SELECT s.id, s.kind, s.quantity, s.start_date, s.need_date, p.code FROM production.suggestion s "
                   "JOIN base.product p ON p.id = s.product_id WHERE s.scenario = $1 AND s.status = 'open' "
                   "AND ($2::bigint[] IS NULL OR s.id = ANY($2)) ORDER BY s.need_date, s.id FOR UPDATE OF s",
                   scenario, [int(i) for i in ids] if ids else None)
    if not rows:
        raise ana.Error("NOTHING_TO_APPROVE", "nenhuma sugestão aberta")
    orders, requests = [], []
    for r in [r for r in rows if r["kind"] == "make"]:
        o = ana.call("production.create_order", product=r["code"], quantity=r["quantity"], due_date=r["need_date"],
                     start_date=r["start_date"], suggestion=r["id"])
        # ana:lint-ok sql_in_loop — one order per suggestion (each with its own components and operations)
        ana.sql_exec("UPDATE production.suggestion SET status = 'approved', order_id = "
                     "(SELECT id FROM production.work_order WHERE number = $2) WHERE id = $1", r["id"], o["order"])
        orders.append(o["order"])
    buys = {}
    for r in rows:
        if r["kind"] == "buy":
            buys.setdefault(r["need_date"], []).append(r)
    for need, group in sorted(buys.items()):
        req = ana.call("supply.request_purchase", reason=f"Planejamento de necessidades — cenário {scenario}",
                       items=[{"product": g["code"], "quantity": g["quantity"]} for g in group], warehouse=warehouse,
                       origin="planning", need_date=max(need, datetime.date.today()), submit=True)
        # ana:lint-ok sql_in_loop — one purchase request per need week
        ana.sql_exec("UPDATE production.suggestion SET status = 'approved', request_id = "
                     "(SELECT id FROM supply.purchase_request WHERE number = $2) WHERE id = ANY($1)",
                     [g["id"] for g in group], req["number"])
        requests.append(req["number"])
    ana.log(f"{len(orders)} ordem(ns) de produção e {len(requests)} solicitação(ões) de compra geradas")
    return {"orders": orders, "requests": requests}
