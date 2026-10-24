# ana:description Entrega o produto acabado da ordem (entrada no estoque) e registra o refugo
# ana:exposed yes
# ana:category Produção/Ordens de produção
"""RF-014-06. Good units enter the warehouse (an order of a project does not: the prototypes go
to the project). The order is completed when good + scrap reach the quantity, or on request."""

from ana_lib.production import common

PARAMS = {
    "order": {"type": "int", "required": True, "label": "ordem", "lookup": {"program": "production.lookup", "params": {"kind": "orders"}}},
    "good_qty": {"type": "decimal", "required": True, "label": "quantidade boa"},
    "scrap_qty": {"type": "decimal", "default": 0, "label": "refugo"},
    "complete": {"type": "bool", "default": False, "label": "concluir a ordem"},
}


def main(order, good_qty, scrap_qty=0, complete=False):
    o = common.order(order, lock=True)
    if o["status"] not in ("released", "in_progress"):
        raise ana.Error("INVALID_STATE", f"ordem {o['number']} não está em produção")
    if good_qty < 0 or scrap_qty < 0 or not (good_qty or scrap_qty):
        raise ana.Error("INVALID_VALUE", "informe as quantidades")
    if good_qty and not o["project_id"]:
        # Spec 038: the finished good enters at the standard unit cost (D inventory / C work_in_process,
        # posted by the database); closing the order posts the difference to the actual cost.
        std_unit = (o["std_cost"] / o["quantity"]) if o["std_cost"] and o["quantity"] else None
        ana.sql_exec("INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, created_by, "
                     "  reason, unit_cost) VALUES ($1, $2, $3, 'in', $4, $5, 'production_receipt', $6)",
                     o["product_id"], o["warehouse_id"], good_qty, f"OP-{o['number']}", ana.context.user, std_unit)
    good, scrap = o["good_qty"] + good_qty, o["scrap_qty"] + scrap_qty
    done = complete or good + scrap >= o["quantity"]
    ana.sql_exec("UPDATE production.work_order SET good_qty = $2, scrap_qty = $3, status = $4 WHERE id = $1",
                 o["id"], good, scrap, "completed" if done else "in_progress")
    if done:
        ana.actions([{"label": "Encerrar e apurar o custo", "program": "production.close_order",
                      "params": {"order": o["number"]}, "style": "primary"}], title="Próximo passo")
    return {"order": o["number"], "good_qty": good, "scrap_qty": scrap, "status": "completed" if done else "in_progress"}
