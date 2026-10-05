# ana:description Aponta operação da ordem: horas, quantidade boa e refugo
# ana:exposed yes
"""RF-014-06. Hours × the resource's cost per hour: D work_in_process / C production_absorbed
(cost center of the order)."""

from decimal import Decimal

from ana_lib.production import common

PARAMS = {
    "order": {"type": "int", "required": True, "label": "ordem", "lookup": {"program": "production.lookup", "params": {"kind": "orders"}}},
    "seq": {"type": "int", "required": True, "label": "operação (sequência)"},
    "hours": {"type": "decimal", "required": True, "label": "horas"},
    "good_qty": {"type": "decimal", "default": 0, "label": "quantidade boa"},
    "scrap_qty": {"type": "decimal", "default": 0, "label": "refugo"},
}


def main(order, seq, hours, good_qty=0, scrap_qty=0):
    o = common.order(order, lock=True)
    if o["status"] not in ("released", "in_progress"):
        raise ana.Error("INVALID_STATE", f"ordem {o['number']} não está em produção")
    op = ana.sql_one("SELECT seq, cost_per_hour, description FROM production.order_operation WHERE order_id = $1 AND seq = $2",
                     o["id"], seq)
    if not op:
        raise ana.Error("OPERATION_NOT_FOUND", f"operação {seq} não existe na ordem {o['number']}")
    if hours < 0 or good_qty < 0 or scrap_qty < 0 or not (hours or good_qty or scrap_qty):
        raise ana.Error("INVALID_VALUE", "informe horas ou quantidades válidas")
    cost = common.money(Decimal(hours) * op["cost_per_hour"])
    doc = f"OP-{o['number']}/{seq}"
    entry = common.post(f"Apontamento da operação {seq} ({op['description']}) da ordem {o['number']}", doc,
                        [("@work_in_process", cost, 0, None), ("@production_absorbed", 0, cost, o["cost_center"])])
    ana.sql_exec("INSERT INTO production.operation_report (order_id, seq, hours, good_qty, scrap_qty, cost, entry_id, reported_by) "
                 "VALUES ($1, $2, $3, $4, $5, $6, $7, $8)", o["id"], seq, hours, good_qty, scrap_qty, cost, entry, ana.context.user)
    ana.sql_exec("UPDATE production.order_operation SET actual_hours = actual_hours + $3, good_qty = good_qty + $4, "
                 "scrap_qty = scrap_qty + $5 WHERE order_id = $1 AND seq = $2", o["id"], seq, hours, good_qty, scrap_qty)
    if o["status"] == "released":
        ana.sql_exec("UPDATE production.work_order SET status = 'in_progress' WHERE id = $1", o["id"])
    return {"order": o["number"], "seq": seq, "cost": cost}
