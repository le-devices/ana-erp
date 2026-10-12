# ana:description Libera mercadoria da quarentena para um depósito ou a descarta (com valor e lançamento automáticos)
# ana:exposed yes
# ana:command quarentena
"""Spec 038 (RF-038-02). Returned goods wait in QUARENTENA (spec 015). After the inspection they are
released to a warehouse (a transfer: same cost, no entry) or scrapped (D inventory losses / C
inventory, posted by the database). Without product: lists what is in quarantine, with the actions."""

from ana_lib.logistics import common
from ana_lib.util import validation as v

QUARANTINE = "QUARENTENA"

PARAMS = {
    "product": {"type": "str", "label": "item", "lookup": {"program": "sales.lookup", "params": {"kind": "products", "warehouse": "QUARENTENA"}}},
    "quantity": {"type": "decimal", "label": "quantidade"},
    "decision": {"type": "str", "default": "release", "label": "decisão", "choices": [["release", "Liberar para o depósito"], ["scrap", "Descartar"]]},
    "to_warehouse": {"type": "str", "default": "CENTRAL", "label": "depósito de destino",
                     "lookup": {"program": "sales.lookup", "params": {"kind": "warehouses"}}},
    "note": {"type": "str", "label": "laudo / observação"},
}


def main(product=None, quantity=None, decision="release", to_warehouse="CENTRAL", note=None):
    q_wh = common.warehouse(QUARANTINE)
    if not product:
        return pending(q_wh)
    v.require(decision in ("release", "scrap"), "INVALID_PARAMETER", "decisão deve ser liberar ou descartar")
    qty = v.positive_decimal(quantity, "quantidade")
    p = common.products([product])[str(product).strip().upper()]
    doc = "QR-%s" % ana.sql_value("SELECT nextval('inventory.count_number_seq')")
    if decision == "release":
        dest = common.warehouse(to_warehouse)
        v.require(dest["id"] != q_wh["id"], "INVALID_PARAMETER", "escolha um depósito diferente da quarentena")
        common.take_stock(q_wh["id"], {p["id"]: qty}, doc, "transfer")
        common.put_stock(dest["id"], {p["id"]: qty}, doc, "transfer")
        ana.log(f"{doc}: {qty} {p['code']} liberado(s) para {dest['code']}" + (f" — {note}" if note else ""))
        return {"document": doc, "decision": "release", "to": dest["code"], "quantity": qty}
    ana.sql("SELECT set_config('ana.cost_center', $1, true)", q_wh["cost_center"] or "")
    moves = common.take_stock(q_wh["id"], {p["id"]: qty}, doc, "scrap")
    m = ana.sql_one("SELECT value, entry_id FROM inventory.stock_movement WHERE id = $1", moves[p["id"]])
    ana.log(f"{doc}: {qty} {p['code']} descartado(s)" + (f" — {note}" if note else ""))
    return {"document": doc, "decision": "scrap", "quantity": qty, "value": -m["value"], "entry": m["entry_id"]}


def pending(q_wh):
    rows = ana.sql("SELECT p.code, p.description, sum(m.quantity) AS q FROM inventory.stock_movement m "
                   "JOIN base.product p ON p.id = m.product_id WHERE m.warehouse_id = $1 GROUP BY p.code, p.description "
                   "HAVING sum(m.quantity) > 0 ORDER BY p.code LIMIT 500", q_wh["id"])
    me = "inventory.release_quarantine"
    ana.table([{"item": r["code"], "descrição": r["description"], "quantidade": r["q"], "_actions": [
        {"label": "Liberar", "program": me, "style": "primary", "params": {"product": r["code"], "quantity": str(r["q"]), "decision": "release"},
         "ask": {"to_warehouse": {"type": "str", "label": "depósito de destino", "default": "CENTRAL"},
                 "note": {"type": "str", "label": "laudo"}}},
        {"label": "Descartar", "program": me, "params": {"product": r["code"], "quantity": str(r["q"]), "decision": "scrap"},
         "ask": {"note": {"type": "str", "label": "motivo", "required": True}}}]} for r in rows],
        title="Em quarentena")
    return {"items": len(rows)}
