# ana:description Registra peça usada na OS: baixa do depósito do técnico (idempotente)
# ana:exposed yes
"""RF-015-08, CA-015-04. Stock leaves the technician's vehicle/kit warehouse."""

from decimal import Decimal

from ana_lib.field import common
from ana_lib.logistics import common as stock

PARAMS = {
    "order": {"type": "int", "required": True, "label": "OS", "lookup": {"program": "logistics.lookup", "params": {"kind": "service_orders"}}},
    "product": {"type": "str", "required": True, "label": "peça", "lookup": {"program": "supply.lookup", "params": {"kind": "products"}}},
    "quantity": {"type": "decimal", "default": 1, "label": "quantidade"},
    "technician": {"type": "int", "label": "técnico (vazio = eu)", "lookup": {"program": "logistics.lookup", "params": {"kind": "technicians"}}},
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
    moves = {}
    if p["kind"] == "goods":
        # Spec 038: the part's cost goes to the project (its cost center) when the order belongs to one,
        # else to the cost of goods sold; the database values and posts the movement.
        reason = "service_part"
        if o["project_id"]:
            reason = "project_material"
            ana.sql("SELECT set_config('ana.cost_center', COALESCE((SELECT cost_center FROM projects.project WHERE id = $1), ''), true)",
                    o["project_id"])
        moves = stock.take_stock(t["warehouse_id"], {p["id"]: q}, f"OS-{o['number']}", reason)
    pid = ana.sql_value("INSERT INTO field.part_usage (order_id, product_id, quantity, unit_price, warehouse_id, stock_movement_id, "
                        "  client_key, created_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id",
                        o["id"], p["id"], q, p["price"], t["warehouse_id"], moves.get(p["id"]), client_key, ana.context.user)
    return {"id": pid, "order": o["number"], "product": p["code"]}
