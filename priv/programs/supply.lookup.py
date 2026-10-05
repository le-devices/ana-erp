# ana:description Opções para campos de escolha de compras
# ana:kind program
# ana:menu no
"""Lookup for forms: [{"value", "label"}].
kind: suppliers | products | warehouses | projects | requests | orders | order_lines."""

PARAMS = {
    "kind": {"type": "str", "required": True,
             "choices": ["suppliers", "products", "warehouses", "projects", "requests", "orders", "order_lines"]},
    "order": {"type": "int", "label": "ordem"},
}

STATUS = {"draft": "rascunho", "submitted": "a aprovar", "approved": "aprovada", "sent": "enviada",
          "partially_received": "recebida em parte"}


def main(kind, order=None):
    if kind == "suppliers":
        rows = ana.sql("SELECT id, name FROM base.party WHERE active AND kind IN ('supplier', 'both') ORDER BY name")
        return [{"value": r["id"], "label": r["name"]} for r in rows]
    if kind == "products":
        rows = ana.sql("SELECT code, description, kind FROM base.product WHERE active ORDER BY code")
        return [{"value": r["code"], "label": f"{r['code']} — {r['description']}" + (" (serviço)" if r["kind"] == "service" else "")}
                for r in rows]
    if kind == "warehouses":
        # ana:lint-ok unbounded_select — warehouses: small master table, the whole list is the answer
        rows = ana.sql("SELECT code, description FROM inventory.warehouse ORDER BY code")
        return [{"value": r["code"], "label": f"{r['code']} — {r['description']}"} for r in rows]
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
