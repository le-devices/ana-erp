# ana:description Inventário físico: digite o contado, veja saldo, diferença e valor, e confirme os ajustes (lançados automaticamente)
# ana:exposed yes
# ana:command contagem
# ana:category Estoque/Inventário e saldos
"""Spec 038 (RF-038-02, CA-038-03). Without lines: the counting sheet of the warehouse (balances).
With lines: preview of the differences at the average cost; confirm=True writes adjustment
movements (document INV-n), which the database values and posts (D inventory / C inventory gains
for leftovers, D inventory losses / C inventory for shortages)."""

import datetime
from decimal import Decimal

from ana_lib.util import validation as v

PARAMS = {
    "warehouse": {"type": "str", "default": "CENTRAL", "label": "depósito", "order": 1, "default_from": "last",
                  "lookup": {"program": "sales.lookup", "params": {"kind": "warehouses"}}},
    "lines": {"type": "list", "label": "itens contados", "add_label": "Adicionar item", "order": 2, "columns": {
        "product": {"type": "str", "required": True, "label": "item", "scan": True,
                    "lookup": {"program": "sales.lookup", "params": {"kind": "products"}}},
        "counted": {"type": "decimal", "required": True, "label": "quantidade contada"}}},
    "note": {"type": "str", "label": "observação", "order": 3},
    "confirm": {"type": "bool", "default": False, "label": "confirmar os ajustes", "order": 4},
}


def main(warehouse="CENTRAL", lines=None, note=None, confirm=False):
    w = ana.sql_one("SELECT id, code, cost_center FROM inventory.warehouse WHERE code = $1", str(warehouse).strip().upper())
    v.require(w, "WAREHOUSE_NOT_FOUND", f"depósito {warehouse} não encontrado")
    if not lines:
        return sheet(w)
    codes = [str(l["product"]).strip().upper() for l in lines]
    v.require(len(set(codes)) == len(codes), "INVALID_PARAMETER", "cada item só uma vez na contagem")
    prods = {r["code"]: r for r in ana.sql(
        "SELECT p.id, p.code, p.description, p.kind FROM base.product p WHERE p.code = ANY($1) AND p.active", codes)}
    missing = [c for c in codes if c not in prods]
    v.require(not missing, "PRODUCT_NOT_FOUND", f"itens não encontrados: {', '.join(missing)}")
    services = [c for c in codes if prods[c]["kind"] != "goods"]
    v.require(not services, "NOT_STOCKABLE", f"serviços não têm estoque: {', '.join(services)}")
    counted = {}
    for l, c in zip(lines, codes):
        q = Decimal(str(l["counted"]))
        v.require(q >= 0, "INVALID_VALUE", f"{c}: a quantidade contada não pode ser negativa")
        counted[prods[c]["id"]] = q
    pids = sorted(counted)
    if confirm:
        ana.sql("SELECT id FROM base.product WHERE id = ANY($1) ORDER BY id FOR UPDATE", pids)
    info = {r["id"]: r for r in ana.sql(
        "SELECT p.id, p.code, p.description, "
        "  COALESCE((SELECT sum(quantity) FROM inventory.stock_movement m WHERE m.product_id = p.id AND m.warehouse_id = $2), 0) AS balance, "
        "  COALESCE((SELECT avg_cost FROM inventory.item_cost c WHERE c.product_id = p.id), inventory.fallback_cost(p.id)) AS cost "
        "FROM base.product p WHERE p.id = ANY($1)", pids, w["id"])}
    rows, diffs, gain, loss = [], {}, Decimal(0), Decimal(0)
    for pid in pids:
        i = info[pid]
        d = counted[pid] - i["balance"]
        value = (d * i["cost"]).quantize(Decimal("0.01"))
        if d:
            diffs[pid] = d
            gain, loss = (gain + value, loss) if d > 0 else (gain, loss - value)
        rows.append({"item": i["code"], "descrição": i["description"], "saldo": i["balance"], "contado": counted[pid],
                     "diferença": d, "custo médio": i["cost"], "valor": value})
    if not confirm:
        ana.metrics([{"label": "Itens contados", "value": len(rows)},
                     {"label": "Com diferença", "value": len(diffs), "status": "warn" if diffs else "ok"},
                     {"label": "Sobras", "value": f"R$ {gain:.2f}"},
                     {"label": "Faltas", "value": f"R$ {loss:.2f}", "status": "bad" if loss else "ok"}],
                    title=f"Prévia da contagem — {w['code']}")
        ana.table(rows, title="Saldo × contado")
        if diffs:
            ana.actions([{"label": "Confirmar os ajustes", "program": "inventory.count", "style": "primary",
                          "params": {"warehouse": w["code"], "lines": lines, "note": note, "confirm": True},
                          "confirm": f"Lançar {len(diffs)} ajuste(s): sobras R$ {gain:.2f}, faltas R$ {loss:.2f}?"}],
                        title="Próximo passo")
        else:
            ana.log("contagem igual ao saldo: nada a ajustar")
        return {"preview": True, "differences": len(diffs), "gains": gain, "losses": loss}
    # Spec 065 (RF-065-07): the date of the last physical inventory, kept by this routine.
    ana.set_value("estoque.ultimo_inventario", datetime.date.today(), reason=f"contagem do depósito {w['code']}")
    if not diffs:
        return {"document": None, "differences": 0}
    doc = "INV-%s" % ana.sql_value("SELECT nextval('inventory.count_number_seq')")
    ana.sql("SELECT set_config('ana.cost_center', $1, true)", w["cost_center"] or "")
    adj = sorted(diffs)
    ana.sql_exec("INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, created_by, reason) "
                 "SELECT p, $2, q::numeric, 'adjustment', $3, $4, CASE WHEN q::numeric > 0 THEN 'adjustment_in' ELSE 'adjustment_out' END "
                 "FROM unnest($1::int[], $5::text[]) AS x(p, q)", adj, w["id"], doc, ana.context.user, [str(diffs[p]) for p in adj])
    entries = ana.sql_value("SELECT array_agg(DISTINCT entry_id) FROM inventory.stock_movement WHERE document = $1", doc)
    if note:
        ana.log(f"contagem {doc}: {note}")
    ana.table([r for r in rows if r["diferença"]], title=f"Ajustes {doc}")
    ana.actions([{"label": "Ver conciliações", "program": "finance.reconciliations"}], title="Próximo passo")
    return {"document": doc, "differences": len(diffs), "gains": gain, "losses": loss, "entries": entries}


def sheet(w):
    rows = ana.sql(
        "SELECT p.code AS item, p.description AS \"descrição\", p.unit AS unidade, sum(m.quantity) AS saldo "
        "FROM inventory.stock_movement m JOIN base.product p ON p.id = m.product_id WHERE m.warehouse_id = $1 "
        "GROUP BY p.code, p.description, p.unit HAVING sum(m.quantity) <> 0 ORDER BY p.code LIMIT $2", w["id"], SHEET_MAX + 1)
    # Spec 042 (E-04): the sheet holds every item with a balance (it was cut at 2000 — items left out of the count).
    # The screen draws 2000 at a time ("Mostrar todas"); search and spreadsheet export see all of them.
    if len(rows) > SHEET_MAX:
        rows = rows[:SHEET_MAX]
        ana.log(f"depósito com mais de {SHEET_MAX} itens com saldo: conte por partes (filtre por grupo ou faixa de código)", "warning")
    ana.table(rows, title=f"Folha de contagem — {w['code']} (informe os itens contados para ver as diferenças)")
    return {"warehouse": w["code"], "items": len(rows)}


SHEET_MAX = 30000
