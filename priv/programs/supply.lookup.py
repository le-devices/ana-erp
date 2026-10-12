# ana:description Opções para campos de escolha de compras
# ana:kind program
# ana:menu no
"""Lookup for forms: [{"value", "label"}].
kind: suppliers | products | warehouses | projects | requests | orders | order_lines."""

from ana_lib.master import core  # spec 040: the single lookup of master records

PARAMS = {
    "kind": {"type": "str", "required": True, "label": "tipo", "choices": ["suppliers", "products", "warehouses", "projects", "requests", "orders", "order_lines"]},
    "order": {"type": "int", "label": "ordem"},
}

STATUS = {"draft": "rascunho", "submitted": "a aprovar", "approved": "aprovada", "sent": "enviada",
          "partially_received": "recebida em parte"}


def main(kind, order=None):
    if kind == "suppliers":
        return core.options("party", by="id", filter_sql="t.kind IN ('supplier', 'both')")
    if kind == "products":
        services = {r["code"] for r in ana.sql("SELECT code FROM base.product WHERE active AND kind = 'service'")}
        return [{**o, "label": o["label"] + (" (serviço)" if o["value"] in services else "")} for o in core.options("product")]
    if kind == "warehouses":
        return core.options("warehouse")
    if kind == "projects":
        rows = ana.sql("SELECT code, name FROM projects.project WHERE status <> 'closed' ORDER BY code")
        return [{"value": r["code"], "label": f"{r['code']} — {r['name']}"} for r in rows]
    if kind == "requests":
        rows = ana.sql("SELECT number, requester, total, status FROM supply.purchase_request "
                       "WHERE status IN ('draft', 'submitted', 'approved') ORDER BY number DESC LIMIT 500")
        return [{"value": r["number"], "label": f"{r['number']} — {r['requester']} — {STATUS[r['status']]} — R$ {r['total']}"}
                for r in rows]
    if kind == "orders":
        rows = ana.sql("SELECT o.number, p.name, o.status FROM supply.purchase_order o JOIN base.party p ON p.id = o.supplier_id "
                       "WHERE o.status IN ('draft', 'sent', 'partially_received') ORDER BY o.number DESC LIMIT 500")
        return [{"value": r["number"], "label": f"{r['number']} — {r['name']} — {STATUS[r['status']]}"} for r in rows]
    if not order:
        return []
    rows = ana.sql("SELECT l.line, pr.code, l.quantity - l.received_qty AS pending FROM supply.purchase_order_line l "
                   "JOIN supply.purchase_order o ON o.id = l.order_id JOIN base.product pr ON pr.id = l.product_id "
                   "WHERE o.number = $1 ORDER BY l.line", order)
    return [{"value": r["line"], "label": f"{r['line']} — {r['code']} (pendente {r['pending']})"} for r in rows]
