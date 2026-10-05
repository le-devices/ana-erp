# ana:description Gera ordens de compra das solicitações aprovadas, por fornecedor
# ana:exposed yes
# ana:command ordens
"""RF-013-04. Approved request lines are grouped by supplier (the line's or the item's
preferred one) and delivery warehouse; price and promised date come from the catalog."""

import datetime

from ana_lib.supply import common

PARAMS = {
    "requests": {"type": "list", "label": "solicitações (vazio = todas as aprovadas)"},
    "send": {"type": "bool", "default": True, "label": "enviar as ordens ao fornecedor"},
    "notes": {"type": "str", "label": "observações"},
}


def main(requests=None, send=True, notes=None):
    reqs = ana.sql("SELECT id, number FROM supply.purchase_request WHERE status = 'approved' "
                   "AND ($1::bigint[] IS NULL OR number = ANY($1)) ORDER BY number FOR UPDATE",
                   [int(n) for n in requests] if requests else None)
    if requests and len(reqs) != len(set(int(n) for n in requests)):
        found = {r["number"] for r in reqs}
        raise ana.Error("INVALID_STATE", "não aprovadas ou inexistentes: " +
                        ", ".join(str(n) for n in sorted(set(int(n) for n in requests) - found)))
    if not reqs:
        raise ana.Error("NOTHING_TO_ORDER", "nenhuma solicitação aprovada para comprar")
    lines = ana.sql(
        "SELECT r.id AS request_id, r.number, r.warehouse_id, r.project_id, r.cost_center, r.need_date, "
        "  l.line, l.product_id, pr.code, l.quantity, l.est_price, l.rebillable, "
        "  COALESCE(l.supplier_id, pref.supplier_id) AS supplier_id, si.price AS catalog_price, si.lead_time_days "
        "FROM supply.purchase_request r JOIN supply.purchase_request_line l ON l.request_id = r.id "
        "JOIN base.product pr ON pr.id = l.product_id "
        "LEFT JOIN supply.supplier_item pref ON pref.product_id = l.product_id AND pref.preferred "
        "LEFT JOIN supply.supplier_item si ON si.product_id = l.product_id "
        "  AND si.supplier_id = COALESCE(l.supplier_id, pref.supplier_id) "
        "WHERE r.id = ANY($1) ORDER BY r.number, l.line", [r["id"] for r in reqs])
    orphan = sorted({f"{l['number']}/{l['code']}" for l in lines if l["supplier_id"] is None})
    if orphan:
        raise ana.Error("NO_SUPPLIER", "sem fornecedor (defina um preferencial no catálogo): " + ", ".join(orphan))

    groups = {}
    for l in lines:
        groups.setdefault((l["supplier_id"], l["warehouse_id"]), []).append(l)
    payment_days = ana.sql_value("SELECT default_payment_days FROM supply.policy WHERE id = 1") or 30
    today = datetime.date.today()
    created = []
    for (supplier_id, warehouse_id), group in sorted(groups.items()):
        s = common.supplier(supplier_id)
        order = ana.sql_one("INSERT INTO supply.purchase_order (supplier_id, warehouse_id, payment_days, notes, created_by) "
                            "VALUES ($1, $2, $3, $4, $5) RETURNING id, number",
                            supplier_id, warehouse_id, payment_days, notes, ana.context.user)
        batch = []
        for n, l in enumerate(group, start=1):
            price = l["catalog_price"] if l["catalog_price"] is not None else l["est_price"]
            promised = today + datetime.timedelta(days=l["lead_time_days"]) if l["lead_time_days"] is not None else l["need_date"]
            batch.append([order["id"], n, l["product_id"], l["quantity"], price, promised, l["request_id"], l["line"],
                          l["project_id"], l["cost_center"], l["rebillable"]])
        ana.sql_batch("INSERT INTO supply.purchase_order_line (order_id, line, product_id, quantity, price, promised_date, "
                      "  request_id, request_line, project_id, cost_center, rebillable) "
                      "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)", batch)
        total = ana.sql_value("UPDATE supply.purchase_order SET total = (SELECT round(sum(quantity * price), 2) "
                              "FROM supply.purchase_order_line WHERE order_id = $1) WHERE id = $1 RETURNING total",
                              order["id"])
        if send:
            ana.sql_exec("UPDATE supply.purchase_order SET status = 'sent', sent_at = now() WHERE id = $1", order["id"])
        created.append({"ordem": order["number"], "fornecedor": s["name"], "linhas": len(batch), "total": total,
                        "situação": "enviada" if send else "rascunho",
                        "_actions": [{"label": "Receber", "program": "supply.receive", "params": {"order": order["number"]},
                                      "confirm": f"Receber tudo o que está pendente na ordem {order['number']}?"}]})
    ana.sql_exec("UPDATE supply.purchase_request SET status = 'ordered' WHERE id = ANY($1)", [r["id"] for r in reqs])
    ana.table(created, title="Ordens de compra geradas")
    return {"orders": [c["ordem"] for c in created], "requests": [r["number"] for r in reqs]}
