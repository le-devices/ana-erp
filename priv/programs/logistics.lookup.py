# ana:description Opções para campos de escolha de logística e serviços em campo
# ana:kind program
# ana:menu no
"""Lookup for forms: [{"value", "label"}]. kind: warehouses | carriers | orders | technicians | service_orders | services | transfers."""

from ana_lib.master import core  # spec 040: the single lookup of master records

PARAMS = {
    "kind": {"type": "str", "required": True, "label": "tipo", "choices": ["warehouses", "carriers", "orders", "technicians", "service_orders", "services", "transfers"]},
}


def main(kind):
    if kind == "warehouses":
        return core.options("warehouse")
    if kind == "carriers":
        return core.options("carrier")
    if kind == "orders":
        rows = ana.sql("SELECT o.number, p.name, s.state FROM sales.sales_order o JOIN base.party p ON p.id = o.customer_id "
                       "JOIN logistics.order_shipping s ON s.sales_order_id = o.id WHERE o.status <> 'CANCELLED' AND s.state <> 'full' "
                       "ORDER BY o.number DESC LIMIT 500")
        return [{"value": r["number"], "label": f"{r['number']} — {r['name']}" + (" (parcial)" if r["state"] == "partial" else "")}
                for r in rows]
    if kind == "technicians":
        rows = ana.sql("SELECT e.id, e.name FROM field.technician t JOIN projects.employee e ON e.id = t.employee_id "
                       "WHERE t.active AND e.active ORDER BY e.name LIMIT 500")
        return [{"value": r["id"], "label": r["name"]} for r in rows]
    if kind == "transfers":
        rows = ana.sql("SELECT t.number, f.code AS src, d.code AS dst, t.status FROM logistics.transfer t "
                       "JOIN inventory.warehouse f ON f.id = t.from_wh JOIN inventory.warehouse d ON d.id = t.to_wh "
                       "WHERE t.status IN ('draft', 'shipped') ORDER BY t.number DESC LIMIT 500")
        names = {"draft": "rascunho", "shipped": "em trânsito"}
        return [{"value": r["number"], "label": f"{r['number']} — {r['src']} → {r['dst']} ({names[r['status']]})"}
                for r in rows]
    if kind == "services":
        rows = ana.sql("SELECT code, description FROM base.product WHERE active AND kind = 'service' ORDER BY code LIMIT 500")
        return [{"value": r["code"], "label": f"{r['code']} — {r['description']}"} for r in rows]
    rows = ana.sql("SELECT o.number, p.name, o.status FROM field.service_order o JOIN base.party p ON p.id = o.customer_id "
                   "WHERE o.status NOT IN ('invoiced', 'cancelled') ORDER BY o.number DESC LIMIT 500")
    return [{"value": r["number"], "label": f"OS {r['number']} — {r['name']} ({r['status']})"} for r in rows]
