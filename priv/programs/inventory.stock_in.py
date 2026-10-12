# ana:description Registra entrada de mercadoria no estoque (sobra, achado ou saldo de abertura), com valor e lançamento automáticos
# ana:exposed yes
# ana:command stockin
"""Stock receipt outside purchases and production; returns the new balance of the product in the
warehouse. Spec 038: the database values the entry (cost given, else the average) and posts
D inventory / C inventory gains (or opening balances)."""

from ana_lib.util import validation as v

PARAMS = {
    "product": {"type": "str", "required": True, "label": "item", "lookup": {"program": "sales.lookup", "params": {"kind": "products"}}},
    "quantity": {"type": "decimal", "required": True, "label": "quantidade"},
    "warehouse": {"type": "str", "default": "CENTRAL", "label": "depósito", "lookup": {"program": "sales.lookup", "params": {"kind": "warehouses"}}},
    "unit_cost": {"type": "decimal", "label": "custo unitário (vazio = custo médio do item)"},
    "reason": {"type": "str", "default": "adjustment_in", "label": "motivo",
               "choices": [["adjustment_in", "Sobra ou achado"], ["opening", "Saldo de abertura"]]},
    "document": {"type": "str", "label": "documento"},
}


def main(product, quantity, warehouse="CENTRAL", unit_cost=None, reason="adjustment_in", document=None):
    qty = v.positive_decimal(quantity, "quantidade")
    v.require(reason in ("adjustment_in", "opening"), "INVALID_PARAMETER", "motivo deve ser sobra/achado ou saldo de abertura")
    v.require(unit_cost is None or unit_cost >= 0, "INVALID_VALUE", "custo unitário não pode ser negativo")
    p = ana.sql_one("SELECT id, kind FROM base.product WHERE code = $1 AND active", product.upper())
    v.require(p, "PRODUCT_NOT_FOUND", f"item {product} não encontrado")
    v.require(p["kind"] == "goods", "NOT_STOCKABLE", f"{product} é serviço e não tem estoque")
    w = ana.sql_one("SELECT id FROM inventory.warehouse WHERE code = $1 AND active", warehouse.upper())
    v.require(w, "WAREHOUSE_NOT_FOUND", f"depósito {warehouse} não encontrado ou inativo")
    m = ana.sql_one(
        "INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, created_by, reason, unit_cost) "
        "VALUES ($1, $2, $3, 'in', $4, $5, $6, $7) RETURNING id", p["id"], w["id"], qty, document, ana.context.user, reason, unit_cost)
    r = ana.sql_one(
        "SELECT (SELECT sum(quantity) FROM inventory.stock_movement WHERE product_id = $1 AND warehouse_id = $2) AS balance, "
        "  m.unit_cost, m.value, m.entry_id FROM inventory.stock_movement m WHERE m.id = $3", p["id"], w["id"], m["id"])
    return {"product": product.upper(), "warehouse": warehouse.upper(), "balance": r["balance"],
            "unit_cost": r["unit_cost"], "value": r["value"], "entry": r["entry_id"]}
