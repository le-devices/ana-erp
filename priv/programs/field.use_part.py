# ana:description Registra peça usada na OS: baixa do depósito do técnico (idempotente)
# ana:exposed yes
"""RF-015-08, CA-015-04. Stock leaves the technician's vehicle/kit warehouse."""

from decimal import Decimal

from ana_lib.field import common
from ana_lib.logistics import common as stock

PARAMS = {
    "order": {"type": "int", "required": True, "label": "OS"},
    "product": {"type": "str", "required": True, "label": "peça"},
    "quantity": {"type": "decimal", "default": 1, "label": "quantidade"},
    "technician": {"type": "int", "label": "técnico (vazio = eu)"},
    "client_key": {"type": "str", "label": "chave do app (idempotência)"},
}


def main(order, product, quantity=1, technician=None, client_key=None):
    if client_key:
        prev = ana.sql_value("SELECT id FROM field.part_usage WHERE client_key = $1", client_key)
        if prev:
            return {"id": prev, "repeated": True}
    o = common.order(order, lock=True)
    common.require_open(o)
    t = common.technician(technician or common.current_technician() or 0)
    if not t["warehouse_id"]:
        raise ana.Error("NO_TECH_WAREHOUSE", f"{t['name']} não tem depósito de veículo/maleta")
    p = stock.products([product])[str(product).strip().upper()]
    q = Decimal(str(quantity))
    if q <= 0:
        raise ana.Error("INVALID_VALUE", "quantidade deve ser positiva")
    moves = stock.take_stock(t["warehouse_id"], {p["id"]: q}, f"OS-{o['number']}") if p["kind"] == "goods" else {}
    pid = ana.sql_value("INSERT INTO field.part_usage (order_id, product_id, quantity, unit_price, warehouse_id, stock_movement_id, "
                        "  client_key, created_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id",
                        o["id"], p["id"], q, p["price"], t["warehouse_id"], moves.get(p["id"]), client_key, ana.context.user)
    return {"id": pid, "order": o["number"], "product": p["code"]}
