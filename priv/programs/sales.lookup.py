# ana:description Opções para campos de vendas: clientes, itens com saldo por depósito, depósitos
# ana:kind program
# ana:menu no
"""Lookup for forms: [{"value", "label", …}]. kind: customers | products | warehouses | orders | invoiced | order_lines | origins. products brings price and stock (in the chosen
warehouse and in the others) so the order screen shows availability while typing."""

from ana_lib.util.format import compact, money

PARAMS = {
    "kind": {"type": "str", "required": True, "label": "tipo", "choices": ["customers", "products", "warehouses", "orders", "invoiced", "order_lines", "origins"]},
    "warehouse": {"type": "str", "label": "depósito"},
    "from_wh": {"type": "str", "label": "depósito de origem (transferência)"},
    "customer": {"type": "int", "label": "cliente"},
    "order": {"type": "int", "label": "pedido"},
}


def main(kind, warehouse=None, from_wh=None, customer=None, order=None):
    warehouse = warehouse or from_wh
    if kind == "customers":
        rows = ana.sql("SELECT p.id, p.name, p.city, p.state, s.blocked FROM base.party p "
                       "CROSS JOIN LATERAL finance.credit_status(p.id, 0) s "
                       "WHERE p.active AND p.kind IN ('customer', 'both') ORDER BY p.name LIMIT 1000")
        return [{"value": r["id"], "label": r["name"] + (f" — {r['city']}/{r['state']}" if r["city"] else "")
                 + (" (bloqueado)" if r["blocked"] else "")} for r in rows]
    if kind == "warehouses":
        rows = ana.sql("SELECT code, description FROM inventory.warehouse WHERE code NOT IN ('TRANSITO', 'QUARENTENA') "
                       "ORDER BY code LIMIT 500")
        return [{"value": r["code"], "label": f"{r['code']} — {r['description']}"} for r in rows]
    if kind == "orders":
        rows = ana.sql("SELECT o.number, p.name, o.total FROM sales.sales_order o JOIN base.party p ON p.id = o.customer_id "
                       "WHERE o.status = 'OPEN' ORDER BY o.number DESC LIMIT 500")
        return [{"value": r["number"], "label": f"{r['number']} — {r['name']} — {money(r['total'])}"} for r in rows]
    if kind == "origins":
        # Spec 032: where a distance starts — the company or a warehouse with coordinates.
        rows = ana.sql("SELECT code, description FROM inventory.warehouse WHERE latitude IS NOT NULL ORDER BY code LIMIT 500")
        return [{"value": "EMPRESA", "label": "Empresa"}] + [{"value": r["code"], "label": f"Depósito {r['code']} — {r['description']}"}
                                                              for r in rows]
    if kind == "invoiced":
        if not customer:
            return []
        rows = ana.sql("SELECT number, total, invoiced_at::date AS day FROM sales.sales_order WHERE customer_id = $1 "
                       "AND status = 'INVOICED' ORDER BY number DESC LIMIT 200", customer)
        return [{"value": r["number"], "label": f"{r['number']} — {money(r['total'])} — faturado em {r['day']:%d/%m/%Y}"} for r in rows]
    if kind == "order_lines":
        if not order:
            return []
        rows = ana.sql("SELECT i.line, p.code, p.description, i.quantity FROM sales.sales_order_item i JOIN sales.sales_order o "
                       "ON o.id = i.order_id JOIN base.product p ON p.id = i.product_id WHERE o.number = $1 ORDER BY i.line", order)
        return [{"value": r["line"], "label": f"{r['line']} — {r['code']} — {r['description']} ({compact(r['quantity'])})"} for r in rows]
    # products: stock here and elsewhere, one aggregate query.
    rows = ana.sql(
        "WITH s AS (SELECT m.product_id, w.code, sum(m.quantity) AS q FROM inventory.stock_movement m "
        "           JOIN inventory.warehouse w ON w.id = m.warehouse_id WHERE w.code NOT IN ('TRANSITO', 'QUARENTENA') "
        "           GROUP BY 1, 2 HAVING sum(m.quantity) <> 0) "
        "SELECT p.code, p.description, p.kind, p.price, "
        "  COALESCE((SELECT q FROM s WHERE s.product_id = p.id AND s.code = upper($1)), 0) AS here, "
        "  COALESCE((SELECT sum(q) FROM s WHERE s.product_id = p.id AND s.code <> upper(COALESCE($1, ''))), 0) AS elsewhere "
        "FROM base.product p WHERE p.active ORDER BY p.code LIMIT 2000", warehouse)
    out = []
    for r in rows:
        if r["kind"] == "service":
            stock = "serviço"
        else:
            stock = f"saldo {compact(r['here'])}" + (f" (+{compact(r['elsewhere'])} em outros)" if r["elsewhere"] else "")
        out.append({"value": r["code"], "label": f"{r['code']} — {r['description']} · {stock} · {money(r['price'] or 0)}",
                    "price": r["price"], "stock": r["here"], "elsewhere": r["elsewhere"], "kind": r["kind"]})
    return out
