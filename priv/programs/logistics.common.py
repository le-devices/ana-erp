# ana:description Regras comuns de logística: depósitos, itens, saldos e movimentos
# ana:kind library
"""Shared by the logistics and field programs (spec 015)."""

from decimal import Decimal

import ana


def warehouse(code):
    w = ana.sql_one("SELECT id, code, cost_center FROM inventory.warehouse WHERE code = $1", str(code).upper())
    if not w:
        raise ana.Error("WAREHOUSE_NOT_FOUND", f"depósito {code} não encontrado")
    return w


def products(codes):
    codes = sorted({str(c).strip().upper() for c in codes})
    found = {r["code"]: r for r in ana.sql(
        "SELECT id, code, description, kind, price FROM base.product WHERE code = ANY($1) AND active", codes)}
    missing = [c for c in codes if c not in found]
    if missing:
        raise ana.Error("PRODUCT_NOT_FOUND", "itens inexistentes: " + ", ".join(missing))
    return found


def take_stock(warehouse_id, wanted, document, reason):
    """wanted: {product_id: qty}. Locks the products in order, checks balances, writes the 'out'
    movements in one batch and returns {product_id: movement_id}. The reason decides how the
    database values and posts them (spec 038)."""
    pids = sorted(wanted)
    if not pids:
        return {}
    ana.sql("SELECT id FROM base.product WHERE id = ANY($1) ORDER BY id FOR UPDATE", pids)
    bal = {r["product_id"]: r["b"] for r in ana.sql(
        "SELECT product_id, sum(quantity) AS b FROM inventory.stock_movement WHERE product_id = ANY($1) AND warehouse_id = $2 "
        "GROUP BY product_id", pids, warehouse_id)}
    short = [(p, bal.get(p, 0), q) for p, q in wanted.items() if bal.get(p, Decimal(0)) < q]
    if short:
        codes = {r["id"]: r["code"] for r in ana.sql("SELECT id, code FROM base.product WHERE id = ANY($1)", [s[0] for s in short])}
        raise ana.Error("INSUFFICIENT_STOCK", "; ".join(f"{codes[p]}: saldo {b}, necessário {q}" for p, b, q in short))
    rows = ana.sql("INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, created_by, reason) "
                   "SELECT p, $2, -q::numeric, 'out', $3, $4, $6 FROM unnest($1::int[], $5::text[]) AS x(p, q) RETURNING id, product_id",
                   pids, warehouse_id, document, ana.context.user, [str(wanted[p]) for p in pids], reason)
    return {r["product_id"]: r["id"] for r in rows}


def put_stock(warehouse_id, given, document, reason):
    """given: {product_id: qty} → 'in' movements in one batch (at the average cost, spec 038)."""
    pids = sorted(p for p, q in given.items() if q > 0)
    if pids:
        ana.sql_exec("INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, created_by, reason) "
                     "SELECT p, $2, q::numeric, 'in', $3, $4, $6 FROM unnest($1::int[], $5::text[]) AS x(p, q)",
                     pids, warehouse_id, document, ana.context.user, [str(given[p]) for p in pids], reason)


def policy():
    return ana.sql_one("SELECT stock_out_on, travel_hour_rate, travel_km_rate FROM logistics.policy WHERE id = 1")
