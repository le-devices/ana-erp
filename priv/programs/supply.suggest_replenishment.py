# ana:description Sugestão de reposição de estoque (ponto de pedido, segurança, máximo)
# ana:exposed yes
# ana:command reposicao
# ana:category Compras/Reposição
"""RF-013-08, RNF-013-03: one set-based query for every rule.
projected = balance + on order − reserved. Below the reorder point → order up to the maximum,
respecting the preferred supplier's minimum lot and multiple. `create` turns the suggestions
into `replenishment` requests (one per warehouse)."""

import math
from decimal import Decimal

PARAMS = {
    "warehouse": {"type": "str", "label": "depósito (vazio = todos)",
                  "lookup": {"program": "supply.lookup", "params": {"kind": "warehouses"}}},
    "create": {"type": "bool", "default": False, "label": "gerar as solicitações de compra"},
}


def round_up(qty, multiple):
    if multiple and multiple > 0:
        return Decimal(math.ceil(qty / multiple)) * multiple
    return qty


def main(warehouse=None, create=False):
    rules = ana.sql(
        "WITH r AS (SELECT r.product_id, r.warehouse_id, r.min_qty, r.safety_qty, r.max_qty, r.method, r.window_days "
        "           FROM supply.replenishment_rule r JOIN inventory.warehouse w ON w.id = r.warehouse_id "
        "           WHERE $1::text IS NULL OR w.code = $1), "
        "bal AS (SELECT m.product_id, m.warehouse_id, sum(m.quantity) AS q FROM inventory.stock_movement m "
        "        JOIN r USING (product_id, warehouse_id) GROUP BY 1, 2), "
        "cons AS (SELECT m.product_id, m.warehouse_id, -sum(m.quantity) AS q FROM inventory.stock_movement m "
        "         JOIN r USING (product_id, warehouse_id) "
        "         WHERE m.kind = 'out' AND m.created_at > now() - make_interval(days => r.window_days) GROUP BY 1, 2) "
        "SELECT r.product_id, r.warehouse_id, r.min_qty, r.safety_qty, r.max_qty, r.method, r.window_days, "
        "  pr.code, pr.description, w.code AS warehouse, COALESCE(bal.q, 0) AS balance, COALESCE(oo.quantity, 0) AS on_order, "
        "  COALESCE(rs.quantity, 0) AS reserved, COALESCE(cons.q, 0) / r.window_days AS daily, "
        "  si.supplier_id, pa.name AS supplier, COALESCE(si.lead_time_days, 0) AS lead_time, "
        "  COALESCE(si.min_qty, 0) AS lot, COALESCE(si.multiple, 0) AS multiple, si.price "
        "FROM r JOIN base.product pr ON pr.id = r.product_id JOIN inventory.warehouse w ON w.id = r.warehouse_id "
        "LEFT JOIN bal USING (product_id, warehouse_id) LEFT JOIN cons USING (product_id, warehouse_id) "
        "LEFT JOIN supply.on_order oo ON oo.product_id = r.product_id AND oo.warehouse_id = r.warehouse_id "
        "LEFT JOIN inventory.reserved rs ON rs.product_id = r.product_id AND rs.warehouse_id = r.warehouse_id "
        "LEFT JOIN supply.supplier_item si ON si.product_id = r.product_id AND si.preferred "
        "LEFT JOIN base.party pa ON pa.id = si.supplier_id "
        "WHERE pr.active ORDER BY w.code, pr.code", warehouse.upper() if warehouse else None)

    suggestions, chart_rows = [], []
    for r in rules:
        projected = r["balance"] + r["on_order"] - r["reserved"]
        if r["method"] == "average_consumption":
            point = max(r["min_qty"], r["safety_qty"] + r["daily"] * r["lead_time"])
        else:
            point = r["min_qty"]
        point = Decimal(point).quantize(Decimal("0.001"))
        chart_rows.append((r["code"], projected, point))
        if projected >= point:
            continue
        qty = round_up(max(r["max_qty"] - projected, r["lot"]), r["multiple"])
        suggestions.append({"depósito": r["warehouse"], "item": r["code"], "descrição": r["description"],
                            "saldo": r["balance"], "em pedido": r["on_order"], "reservado": r["reserved"],
                            "disponível projetado": projected, "ponto de pedido": point, "máximo": r["max_qty"],
                            "sugestão": qty, "fornecedor": r["supplier"] or "— sem preferencial —",
                            "prazo (dias)": r["lead_time"], "_price": r["price"]})

    ana.metrics([{"label": "Itens com regra", "value": len(rules)},
                 {"label": "Abaixo do ponto de pedido", "value": len(suggestions), "status": "warn" if suggestions else "ok"},
                 {"label": "Sem fornecedor preferencial",
                  "value": sum(1 for s in suggestions if s["fornecedor"].startswith("—")),
                  "status": "bad" if any(s["fornecedor"].startswith("—") for s in suggestions) else "ok"}])
    if chart_rows:
        top = sorted(chart_rows, key=lambda c: c[1] - c[2])[:12]
        ana.chart(type="column", title="Disponível projetado × ponto de pedido", subtitle="itens mais próximos de faltar",
                  x=[c[0] for c in top], series=[{"name": "Disponível projetado", "values": [c[1] for c in top]},
                                                 {"name": "Ponto de pedido", "values": [c[2] for c in top]}])
    ana.table([{k: v for k, v in s.items() if not k.startswith("_")} for s in suggestions],
              title="Sugestões de reposição" if suggestions else "Nenhum item abaixo do ponto de pedido")

    created = []
    if create and suggestions:
        by_wh = {}
        for s in suggestions:
            by_wh.setdefault(s["depósito"], []).append({"product": s["item"], "quantity": s["sugestão"],
                                                        **({"price": s["_price"]} if s["_price"] is not None else {})})
        for wh, items in sorted(by_wh.items()):
            r = ana.call("supply.request_purchase", reason="Reposição de estoque (sugestão automática)", items=items,
                         warehouse=wh, origin="replenishment", submit=True)
            created.append(r["number"])
        ana.log(f"solicitações de reposição criadas: {', '.join(map(str, created))}")
    elif suggestions:
        ana.actions([{"label": "Gerar solicitações de compra", "program": "supply.suggest_replenishment",
                      "params": {"warehouse": warehouse, "create": True}, "style": "primary",
                      "confirm": f"Criar solicitações para {len(suggestions)} item(ns)?"}])
    return {"suggestions": [{"warehouse": s["depósito"], "product": s["item"], "quantity": s["sugestão"]} for s in suggestions],
            "requests": created}
