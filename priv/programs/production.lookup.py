# ana:description Opções para campos de escolha da produção
# ana:kind program
# ana:menu no
"""Lookup for forms: [{"value", "label"}]. kind: products | made | resources | warehouses | orders."""

PARAMS = {
    "kind": {"type": "str", "required": True, "label": "tipo", "choices": ["products", "made", "resources", "warehouses", "orders"]},
}

STATUS = {"planned": "planejada", "released": "liberada", "in_progress": "em andamento", "completed": "concluída"}


def main(kind):
    if kind == "products":
        rows = ana.sql("SELECT code, description FROM base.product WHERE active AND kind = 'goods' ORDER BY code LIMIT 2000")
        return [{"value": r["code"], "label": f"{r['code']} — {r['description']}"} for r in rows]
    if kind == "made":
        rows = ana.sql("SELECT p.code, p.description FROM base.product p JOIN production.structure s ON s.product_id = p.id "
                       "AND s.active ORDER BY p.code LIMIT 2000")
        return [{"value": r["code"], "label": f"{r['code']} — {r['description']}"} for r in rows]
    if kind == "resources":
        rows = ana.sql("SELECT code, name FROM production.resource WHERE active ORDER BY code LIMIT 500")
        return [{"value": r["code"], "label": f"{r['code']} — {r['name']}"} for r in rows]
    if kind == "warehouses":
        rows = ana.sql("SELECT code, description FROM inventory.warehouse ORDER BY code LIMIT 500")
        return [{"value": r["code"], "label": f"{r['code']} — {r['description']}"} for r in rows]
    rows = ana.sql("SELECT w.number, p.code, w.quantity, w.status FROM production.work_order w JOIN base.product p "
                   "ON p.id = w.product_id WHERE w.status IN ('planned', 'released', 'in_progress', 'completed') "
                   "ORDER BY w.number DESC LIMIT 500")
    return [{"value": r["number"], "label": f"{r['number']} — {r['code']} × {r['quantity']} ({STATUS[r['status']]})"} for r in rows]
