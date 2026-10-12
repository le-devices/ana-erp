# ana:description Requisita componentes da ordem: baixa do estoque e lançamento em produtos em elaboração
# ana:exposed yes
"""RF-014-06, CA-014-03. Without lines, issues everything still pending. D work_in_process /
C inventory at the unit cost frozen in the order. The database refuses issuing above the
required quantity plus tolerance (RNF-014-03); balances are checked with the products locked."""

from decimal import Decimal

from ana_lib.production import common

PARAMS = {
    "order": {"type": "int", "required": True, "label": "ordem", "lookup": {"program": "production.lookup", "params": {"kind": "orders"}}},
    "lines": {"type": "list", "label": "linhas e quantidades (vazio = tudo o que falta)", "columns": {
        "line": {"type": "int", "required": True, "label": "linha da ordem"},
        "quantity": {"type": "decimal", "required": True, "label": "quantidade"}}},
}


def main(order, lines=None):
    o = common.order(order, lock=True)
    if o["status"] not in ("released", "in_progress"):
        raise ana.Error("INVALID_STATE", f"ordem {o['number']} não está liberada")
    comps = {c["line"]: c for c in ana.sql(
        "SELECT c.line, c.product_id, p.code, c.qty_required, c.issued_qty, c.unit_cost FROM production.order_component c "
        "JOIN base.product p ON p.id = c.product_id WHERE c.order_id = $1 ORDER BY c.line", o["id"])}
    if lines is None:
        wanted = [(n, c["qty_required"] - c["issued_qty"]) for n, c in comps.items() if c["qty_required"] > c["issued_qty"]]
    else:
        wanted = [(int(l["line"]), Decimal(str(l["quantity"]))) for l in lines]
    wanted = [(n, q) for n, q in wanted if q > 0]
    if not wanted:
        raise ana.Error("NOTHING_TO_ISSUE", "nada a requisitar")
    unknown = [n for n, _ in wanted if n not in comps]
    if unknown:
        raise ana.Error("LINE_NOT_FOUND", f"linhas inexistentes: {unknown}")
    pids = sorted({comps[n]["product_id"] for n, _ in wanted})
    ana.sql("SELECT id FROM base.product WHERE id = ANY($1) ORDER BY id FOR UPDATE", pids)
    balance = {r["product_id"]: r["b"] for r in ana.sql(
        "SELECT product_id, sum(quantity) AS b FROM inventory.stock_movement WHERE product_id = ANY($1) AND warehouse_id = $2 "
        "GROUP BY product_id", pids, o["warehouse_id"])}
    need = {}
    for n, q in wanted:
        need[comps[n]["product_id"]] = need.get(comps[n]["product_id"], Decimal(0)) + q
    short = [f"{comps[n]['code']}: saldo {balance.get(comps[n]['product_id'], 0)}, necessário {need[comps[n]['product_id']]}"
             for n, _ in wanted if balance.get(comps[n]["product_id"], 0) < need[comps[n]["product_id"]]]
    if short:
        raise ana.Error("INSUFFICIENT_STOCK", "; ".join(sorted(set(short))))
    doc = f"OP-{o['number']}"
    # Spec 038: components leave at the stock's average cost; the database posts D work_in_process / C inventory.
    moved = ana.sql("INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, created_by, reason) "
                    "SELECT p, $2, -q::numeric, 'out', $3, $4, 'production_issue' FROM unnest($1::int[], $5::text[]) AS x(p, q) "
                    "RETURNING id, product_id",
                    [comps[n]["product_id"] for n, _ in wanted], o["warehouse_id"], doc, ana.context.user,
                    [str(q) for _, q in wanted])
    ana.sql_exec("UPDATE production.order_component c SET issued_qty = c.issued_qty + x.q::numeric "
                 "FROM unnest($2::int[], $3::text[]) AS x(line, q) WHERE c.order_id = $1 AND c.line = x.line",
                 o["id"], [n for n, _ in wanted], [str(q) for _, q in wanted])
    valued = {r["product_id"]: r for r in ana.sql(
        "SELECT product_id, unit_cost, -sum(value) OVER (PARTITION BY product_id) AS v FROM inventory.stock_movement WHERE id = ANY($1)",
        [r["id"] for r in moved])}
    value = sum((r["v"] for r in valued.values()), Decimal(0))
    if o["status"] == "released":
        ana.sql_exec("UPDATE production.work_order SET status = 'in_progress' WHERE id = $1", o["id"])
    ana.table([{"linha": n, "componente": comps[n]["code"], "quantidade": q,
                "valor": common.money(q * valued[comps[n]["product_id"]]["unit_cost"])}
               for n, q in wanted], title=f"Requisição {doc}")
    return {"order": o["number"], "lines": len(wanted), "value": common.money(value)}
