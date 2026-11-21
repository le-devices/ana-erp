# ana:description Planejamento de necessidades: explode estruturas e propõe ordens de produção e compras
# ana:exposed yes
# ana:command mrp
# ana:category Produção/Planejamento
"""RF-014-05, RNF-014-01/02, CA-014-01.

Low-level code of every item by a recursive query; then level by level, in batch:
gross requirements (open sales orders, net forecast, components of firm orders not yet
issued, and the components of what was suggested at the levels above) against on-hand plus
scheduled receipts (open production orders, open purchase orders and purchase requests) per
week; below the safety stock → a lot (minimum, multiple) is suggested, started lead time
before it is needed; a "make" suggestion explodes into its components for the next levels.

Idempotent per scenario: the open suggestions of the scenario are replaced; approved ones and
firm orders are never touched. Long runs: execute asynchronously or schedule it (spec 018)."""

import datetime
import math
from decimal import Decimal

from ana_lib.production import common

PARAMS = {
    "scenario": {"type": "str", "default": "principal", "label": "cenário"},
    "horizon_weeks": {"type": "int", "default": 12, "label": "horizonte (semanas)"},
}
ZERO = Decimal(0)


def lot(net, lot_min, multiple):
    q = max(net, lot_min or ZERO)
    if multiple and multiple > 0:
        q = Decimal(math.ceil(q / multiple)) * multiple
    return q


def main(scenario="principal", horizon_weeks=12):
    horizon_weeks = max(1, min(int(horizon_weeks), 104))
    today = datetime.date.today()
    first = common.monday(today)
    last = first + datetime.timedelta(weeks=horizon_weeks)
    run = ana.sql_value("INSERT INTO production.planning_run (scenario, horizon_weeks, created_by) VALUES ($1, $2, $3) RETURNING id",
                        scenario, horizon_weeks, ana.context.user)

    def week(d):
        return max(first, common.monday(d))

    # Levels: an item's level is the deepest place it appears in any active structure.
    levels = {r["item"]: r["lvl"] for r in ana.sql(
        "WITH RECURSIVE t AS (SELECT s.product_id AS item, 0 AS lvl FROM production.structure s WHERE s.active "
        "  UNION ALL SELECT l.component_id, t.lvl + 1 FROM t JOIN production.structure s ON s.product_id = t.item AND s.active "
        "  JOIN production.structure_line l ON l.structure_id = s.id WHERE t.lvl < 50) "
        "SELECT item, max(lvl) AS lvl FROM t GROUP BY item")}

    gross = {}          # (item, week) -> [qty, [origins]]

    def add(item, wk, qty, origin):
        if qty <= 0 or wk >= last:
            return
        g = gross.setdefault((item, wk), [ZERO, []])
        g[0] += qty
        if len(g[1]) < 20:
            g[1].append(origin)

    # Independent demand: open sales orders.
    for r in ana.sql("SELECT i.product_id, o.number, o.order_date, sum(i.quantity) AS q FROM sales.sales_order_item i "
                     "JOIN sales.sales_order o ON o.id = i.order_id JOIN base.product p ON p.id = i.product_id "
                     "WHERE o.status = 'OPEN' AND p.kind = 'goods' GROUP BY 1, 2, 3"):
        add(r["product_id"], week(r["order_date"]), r["q"], f"pedido {r['number']}")
    # Net forecast: forecast minus the sales orders of the same week (never below zero).
    sales_week = {}
    for (item, wk), g in gross.items():
        sales_week[(item, wk)] = g[0]
    for r in ana.sql("SELECT product_id, week, quantity FROM production.forecast WHERE week >= $1 AND week < $2", first, last):
        net = r["quantity"] - sales_week.get((r["product_id"], r["week"]), ZERO)
        add(r["product_id"], r["week"], net, f"previsão {r['week']:%d/%m}")
    # Components of firm orders not yet issued.
    for r in ana.sql("SELECT c.product_id, w.number, w.start_date, c.qty_required - c.issued_qty AS q "
                     "FROM production.order_component c JOIN production.work_order w ON w.id = c.order_id "
                     "WHERE w.status IN ('planned', 'released', 'in_progress') AND c.qty_required > c.issued_qty"):
        add(r["product_id"], week(r["start_date"]), r["q"], f"ordem {r['number']}")

    # Supply.
    receipts = {}

    def receive(item, wk, qty):
        if qty > 0:
            receipts[(item, wk)] = receipts.get((item, wk), ZERO) + qty
    for r in ana.sql("SELECT product_id, due_date, quantity - good_qty - scrap_qty AS q FROM production.work_order "
                     "WHERE status IN ('planned', 'released', 'in_progress') AND project_id IS NULL"):
        receive(r["product_id"], week(r["due_date"]), r["q"])
    for r in ana.sql("SELECT l.product_id, COALESCE(l.promised_date, current_date) AS d, l.quantity - l.received_qty AS q "
                     "FROM supply.purchase_order_line l JOIN supply.purchase_order o ON o.id = l.order_id "
                     "WHERE o.status IN ('draft', 'sent', 'partially_received') AND l.project_id IS NULL AND l.received_qty < l.quantity"):
        receive(r["product_id"], week(r["d"]), r["q"])
    for r in ana.sql("SELECT l.product_id, COALESCE(r.need_date, current_date) AS d, l.quantity AS q "
                     "FROM supply.purchase_request r JOIN supply.purchase_request_line l ON l.request_id = r.id "
                     "WHERE r.status IN ('submitted', 'approved') AND r.project_id IS NULL"):
        receive(r["product_id"], week(r["d"]), r["q"])

    items = set(levels) | {k[0] for k in gross}
    onhand = {r["product_id"]: r["q"] for r in ana.sql(
        "SELECT product_id, sum(quantity) AS q FROM inventory.stock_movement WHERE product_id = ANY($1) GROUP BY product_id",
        sorted(items))}
    plans = {r["product_id"]: r for r in ana.sql(
        "SELECT ip.product_id, ip.make_or_buy, ip.lead_time_days, ip.lot_min, ip.lot_multiple, ip.safety_stock, "
        "  si.lead_time_days AS supplier_lead FROM production.item_plan ip "
        "LEFT JOIN supply.supplier_item si ON si.product_id = ip.product_id AND si.preferred WHERE ip.product_id = ANY($1)",
        sorted(items))}
    supplier_lead = {r["product_id"]: r["lead_time_days"] for r in ana.sql(
        "SELECT product_id, lead_time_days FROM supply.supplier_item WHERE preferred AND product_id = ANY($1)", sorted(items))}
    structures = common.active_structures(sorted(items))

    suggestions = []
    for level in range(0, (max(levels.values()) if levels else 0) + 1):
        level_items = sorted(i for i in items if levels.get(i, 0) == level)
        new_structs = [i for i in level_items if i not in structures]
        if new_structs:
            structures.update(common.active_structures(new_structs))
        for item in level_items:
            pl = plans.get(item, {})
            make = (pl.get("make_or_buy") == "make") if pl else (item in structures)
            lead = pl.get("lead_time_days") or (0 if make else (supplier_lead.get(item) or 0))
            safety = Decimal(pl.get("safety_stock") or 0)
            projected = Decimal(onhand.get(item, 0))
            wk = first
            while wk < last:
                g = gross.get((item, wk))
                projected += receipts.get((item, wk), ZERO) - (g[0] if g else ZERO)
                if projected < safety:
                    qty = lot(safety - projected, Decimal(pl.get("lot_min") or 0), Decimal(pl.get("lot_multiple") or 0))
                    start = wk - datetime.timedelta(days=lead)
                    late = start < today
                    origin = (g[1] if g else []) + (["estoque de segurança"] if safety else []) + (["atrasada"] if late else [])
                    key = len(suggestions)
                    suggestions.append(["make" if make and item in structures else "buy", item, qty,
                                        max(start, today), wk, origin])
                    projected += qty
                    if make and item in structures:
                        start_wk = week(max(start, today))
                        for comp, cqty in explode_lines(structures, item, qty):
                            add(comp, start_wk, cqty, f"sugestão {key + 1}: fabricar {qty} de #{item}")
                            if comp not in levels:
                                levels[comp] = level + 1
                                items.add(comp)
                wk += datetime.timedelta(weeks=1)
        # Components discovered at this level may need their own plans and structures.
        missing = [i for i in items if i not in plans and levels.get(i, 0) > level]
        if missing:
            # ana:lint-ok sql_in_loop — one query per structure level (a handful), never per item
            for r in ana.sql("SELECT product_id, make_or_buy, lead_time_days, lot_min, lot_multiple, safety_stock "
                             "FROM production.item_plan WHERE product_id = ANY($1)", sorted(missing)):
                plans[r["product_id"]] = r
            # ana:lint-ok sql_in_loop — one query per structure level (a handful), never per item
            for r in ana.sql("SELECT product_id, lead_time_days FROM supply.supplier_item WHERE preferred AND product_id = ANY($1)",
                             sorted(missing)):
                supplier_lead[r["product_id"]] = r["lead_time_days"]

    # Replace the open suggestions of the scenario (approved ones stay).
    ana.sql_exec("UPDATE production.suggestion SET status = 'discarded' WHERE scenario = $1 AND status = 'open'", scenario)
    if suggestions:
        ana.sql_batch("INSERT INTO production.suggestion (run_id, scenario, kind, product_id, quantity, start_date, need_date, origin) "
                      "VALUES ($1, $2, $3, $4, $5, $6, $7, $8::text::jsonb)",
                      [[run, scenario, k, i, q, s, n, ana_json(o)] for k, i, q, s, n, o in suggestions])
    ana.sql_exec("UPDATE production.planning_run SET status = 'done', suggestions = $2, finished_at = now() WHERE id = $1",
                 run, len(suggestions))
    codes = {r["id"]: r["code"] for r in ana.sql("SELECT id, code FROM base.product WHERE id = ANY($1)",
                                                 sorted({s[1] for s in suggestions}))}
    ana.metrics([{"label": "Sugestões", "value": len(suggestions)},
                 {"label": "Fabricar", "value": sum(1 for s in suggestions if s[0] == "make")},
                 {"label": "Comprar", "value": sum(1 for s in suggestions if s[0] == "buy")},
                 {"label": "Atrasadas", "value": sum(1 for s in suggestions if "atrasada" in s[5]),
                  "status": "bad" if any("atrasada" in s[5] for s in suggestions) else "ok"}])
    ana.table([{"ação": "fabricar" if k == "make" else "comprar", "item": codes[i], "quantidade": q, "início": s,
                "necessário em": n, "origem": "; ".join(o).replace("#", "")}
               for k, i, q, s, n, o in suggestions[:500]], title=f"Sugestões — cenário {scenario}")
    if suggestions:
        ana.actions([{"label": "Aprovar todas", "program": "production.approve_suggestions", "params": {"scenario": scenario},
                      "style": "primary", "confirm": f"Gerar {len(suggestions)} ordem(ns) e solicitação(ões)?"}],
                    title="Próximo passo")
    return {"run": run, "suggestions": [{"kind": k, "product": codes[i], "quantity": q, "start": s, "need": n}
                                        for k, i, q, s, n, _ in suggestions]}


def explode_lines(structures, item, qty):
    """One level down (phantoms crossed), quantities with scrap."""
    out = {}
    frontier = [(l, Decimal(qty)) for l in structures.get(item, [])]
    depth = 0
    while frontier and depth < 50:
        depth += 1
        nxt = []
        for l, q in frontier:
            need = q * Decimal(l["quantity"]) * (1 + Decimal(l["scrap_pct"]) / 100)
            if l["phantom"]:
                sub = structures.get(l["component_id"]) or common.active_structures([l["component_id"]]).get(l["component_id"])
                if sub:
                    structures[l["component_id"]] = sub
                    nxt += [(sl, need) for sl in sub]
                    continue
            out[l["component_id"]] = out.get(l["component_id"], ZERO) + need
        frontier = nxt
    return [(k, v.quantize(Decimal("0.001"))) for k, v in out.items()]


def ana_json(v):
    import json
    return json.dumps(v, ensure_ascii=False)
