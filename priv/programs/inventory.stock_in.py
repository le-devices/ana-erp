# ana:description Registra entrada de mercadoria no estoque
# ana:exposed yes
# ana:command stockin
"""Stock receipt; returns the new balance of the product in the warehouse."""

from ana_lib.util import validation as v

PARAMS = {
    "product": {"type": "str", "required": True},
    "quantity": {"type": "decimal", "required": True},
    "warehouse": {"type": "str", "default": "CENTRAL"},
    "document": {"type": "str"},
}


def main(product, quantity, warehouse="CENTRAL", document=None):
    qty = v.positive_decimal(quantity, "quantidade")
    p = ana.sql_one("SELECT id, kind FROM base.product WHERE code = $1 AND active", product.upper())
    v.require(p, "PRODUCT_NOT_FOUND", f"item {product} não encontrado")
    v.require(p["kind"] == "goods", "NOT_STOCKABLE", f"{product} é serviço e não tem estoque")
    w = ana.sql_one("SELECT id FROM inventory.warehouse WHERE code = $1", warehouse.upper())
    v.require(w, "WAREHOUSE_NOT_FOUND", f"depósito {warehouse} não encontrado")
    ana.sql_exec(
        "INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, created_by) "
        "VALUES ($1, $2, $3, 'in', $4, $5)", p["id"], w["id"], qty, document, ana.context.user)
    balance = ana.sql_value(
        "SELECT sum(quantity) FROM inventory.stock_movement WHERE product_id = $1 AND warehouse_id = $2",
        p["id"], w["id"])
    return {"product": product.upper(), "warehouse": warehouse.upper(), "balance": balance}
