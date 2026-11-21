# ana:description Libera ordem de produção: reserva os componentes e mostra faltas
# ana:exposed yes
# ana:category Produção/Ordens de produção
"""RF-014-06. Reserved quantities count in inventory.reserved (specs 013/015). Shortages are
shown (reserved anyway: purchasing sees them in the replenishment suggestion)."""

from ana_lib.production import common

PARAMS = {"order": {"type": "int", "required": True, "label": "ordem", "lookup": {"program": "production.lookup", "params": {"kind": "orders"}}}}


def main(order):
    o = common.order(order, lock=True)
    if o["status"] != "planned":
        raise ana.Error("INVALID_STATE", f"ordem {o['number']} não está planejada")
    ana.sql_exec("UPDATE production.order_component SET reserved_qty = qty_required WHERE order_id = $1", o["id"])
    ana.sql_exec("UPDATE production.work_order SET status = 'released', released_at = now() WHERE id = $1", o["id"])
    short = ana.sql(
        "SELECT p.code, p.description, c.qty_required, COALESCE(b.balance, 0) AS balance, COALESCE(r.quantity, 0) AS reserved "
        "FROM production.order_component c JOIN base.product p ON p.id = c.product_id "
        "LEFT JOIN (SELECT product_id, sum(quantity) AS balance FROM inventory.stock_movement WHERE warehouse_id = $2 "
        "           GROUP BY product_id) b ON b.product_id = c.product_id "
        "LEFT JOIN inventory.reserved r ON r.product_id = c.product_id AND r.warehouse_id = $2 "
        "WHERE c.order_id = $1 ORDER BY p.code", o["id"], o["warehouse_id"])
    short = [s for s in short if s["balance"] < s["reserved"]]
    if short:
        ana.table([{"componente": f"{s['code']} — {s['description']}", "necessário": s["qty_required"], "saldo": s["balance"],
                    "reservado (todas as ordens)": s["reserved"], "falta": s["reserved"] - s["balance"]} for s in short],
                  title="Faltas de componentes")
    ana.actions([{"label": "Requisitar componentes", "program": "production.issue_components", "params": {"order": o["number"]},
                  "style": "primary"}], title="Próximo passo")
    return {"order": o["number"], "status": "released", "shortages": len(short)}
