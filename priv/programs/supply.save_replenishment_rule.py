# ana:description Parâmetros de reposição por item e depósito
# ana:exposed yes
"""RF-013-07. Reorder point (minimum), safety stock, maximum, method and consumption window."""

from ana_lib.supply import common

PARAMS = {
    "product": {"type": "str", "required": True, "label": "item", "lookup": {"program": "supply.lookup", "params": {"kind": "products"}}},
    "warehouse": {"type": "str", "default": "CENTRAL", "label": "depósito", "lookup": {"program": "supply.lookup", "params": {"kind": "warehouses"}}},
    "min_qty": {"type": "decimal", "required": True, "label": "ponto de pedido (mínimo)"},
    "max_qty": {"type": "decimal", "required": True, "label": "estoque máximo"},
    "safety_qty": {"type": "decimal", "default": 0, "label": "estoque de segurança"},
    "method": {"type": "str", "default": "min_max", "label": "método",
               "choices": [["min_max", "Mínimo e máximo"], ["average_consumption", "Consumo médio × prazo"]]},
    "window_days": {"type": "int", "default": 90, "label": "janela de consumo (dias)"},
    "remove": {"type": "bool", "default": False, "label": "remover a regra"},
}


def main(product, min_qty, max_qty, warehouse="CENTRAL", safety_qty=0, method="min_max", window_days=90, remove=False):
    p = common.products([product])[str(product).upper()]
    if p["kind"] != "goods":
        raise ana.Error("NOT_STOCKABLE", f"{p['code']} é serviço e não tem estoque")
    w = common.warehouse(warehouse)
    if remove:
        n = ana.sql_exec("DELETE FROM supply.replenishment_rule WHERE product_id = $1 AND warehouse_id = $2", p["id"], w["id"])
        return {"removed": n}
    if max_qty < min_qty:
        raise ana.Error("INVALID_VALUE", "o máximo não pode ser menor que o ponto de pedido")
    ana.sql_exec("INSERT INTO supply.replenishment_rule (product_id, warehouse_id, min_qty, safety_qty, max_qty, method, "
                 "  window_days) VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT (product_id, warehouse_id) DO UPDATE "
                 "SET min_qty = EXCLUDED.min_qty, safety_qty = EXCLUDED.safety_qty, max_qty = EXCLUDED.max_qty, "
                 "  method = EXCLUDED.method, window_days = EXCLUDED.window_days",
                 p["id"], w["id"], min_qty, safety_qty, max_qty, method, window_days)
    return {"product": p["code"], "warehouse": w["code"]}
