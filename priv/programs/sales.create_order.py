# ana:description Cria pedido de venda com itens
# ana:exposed yes
# ana:command order
"""Creates an OPEN order. Default price = the product's list price.

Example params:
  {"customer": 1, "items": [{"product": "CAFE-500", "quantity": 2}]}
"""

from decimal import Decimal

from ana_lib.util import validation as v

PARAMS = {
    "customer": {"type": "int", "required": True},
    "items": {"type": "list", "required": True},
    "warehouse": {"type": "str", "default": "CENTRAL"},
    "notes": {"type": "str"},
}


def main(customer, items, warehouse="CENTRAL", notes=None):
    v.require(0 < len(items) <= 500, "INVALID_ITEMS", "o pedido deve ter de 1 a 500 itens")
    c = ana.sql_one("SELECT id, name FROM base.party "
                    "WHERE id = $1 AND active AND kind IN ('customer', 'both')", customer)
    v.require(c, "CUSTOMER_NOT_FOUND", f"cliente {customer} não encontrado")
    w = ana.sql_one("SELECT id FROM inventory.warehouse WHERE code = $1", warehouse.upper())
    v.require(w, "WAREHOUSE_NOT_FOUND", f"depósito {warehouse} não encontrado")

    codes = sorted({str(i.get("product", "")).upper() for i in items})
    products = {p["code"]: p for p in ana.sql(
        "SELECT id, code, price FROM base.product WHERE code = ANY($1) AND active", codes)}
    missing = [code for code in codes if code not in products]
    v.require(not missing, "PRODUCT_NOT_FOUND", f"itens inexistentes: {', '.join(missing)}")

    order = ana.sql_one(
        "INSERT INTO sales.sales_order (customer_id, warehouse_id, notes, created_by) "
        "VALUES ($1, $2, $3, $4) RETURNING id, number", customer, w["id"], notes, ana.context.user)

    batch = []
    for n, item in enumerate(items, start=1):
        p = products[str(item["product"]).upper()]
        qty = v.positive_decimal(item.get("quantity"), f"quantidade do item {n}")
        price = Decimal(str(item["price"])) if item.get("price") is not None else p["price"]
        v.require(price >= 0, "INVALID_VALUE", f"preço do item {n} negativo")
        batch.append([order["id"], n, p["id"], qty, price])
    ana.sql_batch("INSERT INTO sales.sales_order_item (order_id, line, product_id, quantity, price) "
                  "VALUES ($1, $2, $3, $4, $5)", batch)

    total = ana.sql_value("SELECT total FROM sales.sales_order WHERE id = $1", order["id"])
    ana.log(f"pedido {order['number']} criado para {c['name']}: total {total}")
    return {"number": order["number"], "total": total, "items": len(batch)}
