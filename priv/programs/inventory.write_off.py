# ana:description Baixa de estoque por perda ou descarte, com valor e lançamento automáticos
# ana:exposed yes
# ana:command baixa_estoque
# ana:category Estoque/Movimentações
# ana:confirm A mercadoria sai do estoque como perda ou descarte, com o lançamento contábil. Não há desfazer: a correção é uma nova entrada de estoque.
"""Spec 038 (RF-038-02). Loss (theft, damage, expiry) or scrap: the item leaves at the average cost
and the database posts D inventory losses / C inventory, with the warehouse's cost center."""

from decimal import Decimal

from ana_lib.logistics import common
from ana_lib.util import validation as v

PARAMS = {
    "product": {"type": "str", "required": True, "label": "item", "lookup": {"program": "sales.lookup", "params": {"kind": "products"}}},
    "quantity": {"type": "decimal", "required": True, "label": "quantidade"},
    "warehouse": {"type": "str", "default": "CENTRAL", "label": "depósito", "lookup": {"program": "sales.lookup", "params": {"kind": "warehouses"}}},
    "kind": {"type": "str", "default": "loss", "label": "tipo", "choices": [["loss", "Perda (avaria, validade, extravio)"], ["scrap", "Descarte"]]},
    "reason": {"type": "str", "required": True, "label": "motivo"},
}


def main(product, quantity, reason, warehouse="CENTRAL", kind="loss"):
    v.require(kind in ("loss", "scrap"), "INVALID_PARAMETER", "tipo deve ser perda ou descarte")
    v.require(len((reason or "").strip()) >= 3, "INVALID_PARAMETER", "diga o motivo da baixa")
    q = v.positive_decimal(quantity, "quantidade")
    w = common.warehouse(warehouse)
    p = common.products([product])[str(product).strip().upper()]
    v.require(p["kind"] == "goods", "NOT_STOCKABLE", f"{p['code']} é serviço e não tem estoque")
    doc = "BX-%s" % ana.sql_value("SELECT nextval('inventory.count_number_seq')")
    ana.sql("SELECT set_config('ana.cost_center', $1, true)", w["cost_center"] or "")
    moves = common.take_stock(w["id"], {p["id"]: q}, doc, kind)
    m = ana.sql_one("SELECT unit_cost, value, entry_id FROM inventory.stock_movement WHERE id = $1", moves[p["id"]])
    ana.log(f"{'perda' if kind == 'loss' else 'descarte'} {doc} de {q} {p['code']} em {w['code']}: {reason.strip()}")
    return {"document": doc, "product": p["code"], "quantity": q, "unit_cost": m["unit_cost"], "value": -Decimal(m["value"]),
            "entry": m["entry_id"]}
