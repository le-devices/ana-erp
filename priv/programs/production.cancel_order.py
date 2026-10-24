# ana:description Cancela ordem de produção ainda sem componentes requisitados (libera as reservas)
# ana:exposed yes
# ana:category Produção/Ordens de produção
"""RF-014-06. An order with issued components or reported hours is finished (deliver/close),
never cancelled: what was consumed must stay accounted."""

from ana_lib.production import common

PARAMS = {"order": {"type": "int", "required": True, "label": "ordem", "lookup": {"program": "production.lookup", "params": {"kind": "orders"}}},
          "reason": {"type": "str", "required": True, "label": "motivo"}}


def main(order, reason):
    o = common.order(order, lock=True)
    used = ana.sql_value("SELECT (SELECT COALESCE(sum(issued_qty), 0) FROM production.order_component WHERE order_id = $1) + "
                         "(SELECT COALESCE(sum(hours), 0) FROM production.operation_report WHERE order_id = $1)", o["id"])
    if used:
        raise ana.Error("ORDER_IN_USE", "a ordem já consumiu componentes ou horas: entregue e encerre")
    ana.sql_exec("UPDATE production.work_order SET status = 'cancelled' WHERE id = $1", o["id"])
    ana.log(f"ordem {o['number']} cancelada: {reason}")
    return {"order": o["number"], "status": "cancelled"}
