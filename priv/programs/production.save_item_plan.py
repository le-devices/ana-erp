# ana:description Parâmetros de planejamento do item: fazer ou comprar, prazo, lote, segurança e custo padrão
# ana:exposed yes
# ana:category Produção/Engenharia do produto
"""RF-014-05 (lot sizing) and the standard cost used by the production orders."""

from ana_lib.production import common

PARAMS = {
    "product": {"type": "str", "required": True, "label": "item", "lookup": {"program": "production.lookup", "params": {"kind": "products"}}},
    "make_or_buy": {"type": "str", "default": "buy", "label": "origem", "choices": [["make", "Fabricar"], ["buy", "Comprar"]]},
    "lead_time_days": {"type": "int", "default": 0, "label": "prazo (dias)"},
    "lot_min": {"type": "decimal", "default": 0, "label": "lote mínimo"},
    "lot_multiple": {"type": "decimal", "default": 0, "label": "múltiplo do lote"},
    "safety_stock": {"type": "decimal", "default": 0, "label": "estoque de segurança"},
    "warehouse": {"type": "str", "label": "depósito", "lookup": {"program": "production.lookup", "params": {"kind": "warehouses"}}},
    "standard_cost": {"type": "decimal", "label": "custo padrão unitário"},
}


def main(product, make_or_buy="buy", lead_time_days=0, lot_min=0, lot_multiple=0, safety_stock=0, warehouse=None,
         standard_cost=None):
    p = common.product(product)
    w = common.warehouse(warehouse)["id"] if warehouse else None
    ana.sql_exec("INSERT INTO production.item_plan (product_id, make_or_buy, lead_time_days, lot_min, lot_multiple, "
                 "  safety_stock, warehouse_id, standard_cost) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) "
                 "ON CONFLICT (product_id) DO UPDATE SET make_or_buy = EXCLUDED.make_or_buy, lead_time_days = EXCLUDED.lead_time_days, "
                 "  lot_min = EXCLUDED.lot_min, lot_multiple = EXCLUDED.lot_multiple, safety_stock = EXCLUDED.safety_stock, "
                 "  warehouse_id = EXCLUDED.warehouse_id, standard_cost = EXCLUDED.standard_cost",
                 p["id"], make_or_buy, lead_time_days, lot_min, lot_multiple, safety_stock, w, standard_cost)
    return {"product": p["code"]}
