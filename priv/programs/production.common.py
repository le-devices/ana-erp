# ana:description Regras comuns de produção: itens, custos, explosão de estruturas e lançamentos
# ana:kind library
"""Shared by the production programs (spec 014)."""

import datetime
from decimal import Decimal, ROUND_HALF_UP

import ana

ZERO = Decimal(0)
CENT = Decimal("0.01")


def money(v):
    return Decimal(v).quantize(CENT, rounding=ROUND_HALF_UP)


def products(codes):
    codes = sorted({str(c).strip().upper() for c in codes})
    found = {r["code"]: r for r in ana.sql(
        "SELECT id, code, description, kind FROM base.product WHERE code = ANY($1) AND active", codes)}
    missing = [c for c in codes if c not in found]
    if missing:
        raise ana.Error("PRODUCT_NOT_FOUND", "itens inexistentes: " + ", ".join(missing))
    return found


def product(code):
    return products([code])[str(code).strip().upper()]


def warehouse(code):
    w = ana.sql_one("SELECT id, code, cost_center FROM inventory.warehouse WHERE code = $1", str(code).upper())
    if not w:
        raise ana.Error("WAREHOUSE_NOT_FOUND", f"depósito {code} não encontrado")
    return w


def unit_costs(product_ids):
    """{product_id: cost}: standard cost, else the preferred supplier's price (spec 013), else 0."""
    if not product_ids:
        return {}
    rows = ana.sql("SELECT p.id, COALESCE(ip.standard_cost, si.price, 0) AS cost FROM base.product p "
                   "LEFT JOIN production.item_plan ip ON ip.product_id = p.id "
                   "LEFT JOIN supply.supplier_item si ON si.product_id = p.id AND si.preferred "
                   "WHERE p.id = ANY($1)", sorted(set(product_ids)))
    return {r["id"]: Decimal(r["cost"]) for r in rows}


def active_structures(product_ids):
    """{parent_id: [line…]} for the active structures of the given parents (one query)."""
    out = {}
    if not product_ids:
        return out
    for r in ana.sql("SELECT s.product_id, s.id AS structure_id, l.line, l.component_id, l.quantity, l.scrap_pct, l.phantom "
                     "FROM production.structure s JOIN production.structure_line l ON l.structure_id = s.id "
                     "WHERE s.active AND s.product_id = ANY($1) ORDER BY s.product_id, l.line", sorted(set(product_ids))):
        out.setdefault(r["product_id"], []).append(r)
    return out


def explode(product_id, quantity):
    """Components for `quantity` of the item, crossing phantom sub-assemblies (not stocked):
    [(component_id, qty)], quantities with scrap. Raises when the item has no structure."""
    lines = active_structures([product_id]).get(product_id)
    if not lines:
        raise ana.Error("NO_STRUCTURE", "o item não tem estrutura ativa")
    out = {}
    frontier = [(l, Decimal(quantity)) for l in lines]
    depth = 0
    while frontier:
        depth += 1
        if depth > 50:
            raise ana.Error("STRUCTURE_CYCLE", "estrutura profunda demais")
        nxt = []
        subs = active_structures([l["component_id"] for l, _ in frontier if l["phantom"]])
        for l, q in frontier:
            need = q * Decimal(l["quantity"]) * (1 + Decimal(l["scrap_pct"]) / 100)
            if l["phantom"] and subs.get(l["component_id"]):
                nxt += [(sl, need) for sl in subs[l["component_id"]]]
            else:
                out[l["component_id"]] = out.get(l["component_id"], ZERO) + need
        frontier = nxt
    return [(k, v.quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP)) for k, v in out.items()]


def post(memo, document, lines, entry_date=None):
    """lines: [(account_key_or_code, debit, credit, cost_center)]; '@key' = finance.account_for(key)."""
    lines = [l for l in lines if l[1] or l[2]]
    if not lines:
        return None
    entry = ana.sql_value("INSERT INTO finance.journal_entry (entry_date, memo, document, created_by) VALUES ($1, $2, $3, $4) "
                          "RETURNING id", entry_date or datetime.date.today(), memo[:200], document, ana.context.user)
    ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit, cost_center) VALUES ($1, "
                  "CASE WHEN left($2, 1) = '@' THEN finance.account_for(substr($2, 2)) ELSE $2 END, $3, $4, $5)",
                  [[entry, a, money(d), money(c), cc] for a, d, c, cc in lines])
    return entry


def order(number, lock=False):
    o = ana.sql_one("SELECT w.id, w.number, w.product_id, w.quantity, w.warehouse_id, w.start_date, w.due_date, w.priority, "
                    "  w.project_id, w.cost_center, w.status, w.good_qty, w.scrap_qty, w.std_cost, p.code, p.description "
                    "FROM production.work_order w JOIN base.product p ON p.id = w.product_id "
                    "WHERE w.number = $1" + (" FOR UPDATE OF w" if lock else ""), number)
    if not o:
        raise ana.Error("ORDER_NOT_FOUND", f"ordem de produção {number} não encontrada")
    return o


def monday(d):
    return d - datetime.timedelta(days=d.weekday())
