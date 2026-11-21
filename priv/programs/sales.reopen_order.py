# ana:description Reabre pedido cancelado (e o suprimento cancelado junto com ele), como estava antes do cancelamento
# ana:category Vendas/Pedidos
"""Spec 050 (D5, CA-050-03): the undo of "Cancelar pedido", by document. The order goes back to open; purchase requests
cancelled with it go back to the status they had; work orders cancelled with it go back to planned. Only what was
cancelled together with this order is touched (the reason written by the cancellation says so); anything changed since
is left as it is and listed."""

from ana_lib.util import validation as v
from ana_lib.util.format import status_text

PARAMS = {
    "number": {"type": "int", "required": True, "label": "pedido", "lookup": {"program": "sales.lookup", "params": {"kind": "orders"}}},
    "requests": {"type": "list", "label": "solicitações de compra canceladas com o pedido", "default": []},
    "work_orders": {"type": "list", "label": "ordens de produção canceladas com o pedido", "default": []},
}
BEFORE = ("draft", "submitted", "approved")


def main(number, requests=None, work_orders=None):
    o = ana.sql_one("SELECT id, status FROM sales.sales_order WHERE number = $1 FOR UPDATE", number)
    v.require(o, "ORDER_NOT_FOUND", f"pedido {number} não encontrado")
    v.require(o["status"] == "CANCELLED", "ORDER_NOT_CANCELLED", f"pedido {number} está {status_text(o['status'])}")
    ana.sql_exec("UPDATE sales.sales_order SET status = 'OPEN' WHERE id = $1", o["id"])
    reason = f"pedido de venda {number} cancelado"
    restored, kept = [], []
    for r in requests or []:
        n, before = r.get("number"), r.get("status")
        if before not in BEFORE:
            continue
        # ana:lint-ok sql_in_loop — the few requests cancelled with this order
        done = ana.sql_exec("UPDATE supply.purchase_request r SET status = $2, rejection_reason = NULL "
                            "WHERE r.number = $1 AND r.status = 'cancelled' AND r.rejection_reason = $3 "
                            "AND EXISTS (SELECT 1 FROM supply.purchase_request_line l WHERE l.request_id = r.id "
                            "AND l.sales_order_id = $4)", n, before, reason, o["id"])
        (restored if done else kept).append(f"solicitação de compra {n}")
    for n in work_orders or []:
        # ana:lint-ok sql_in_loop — the few work orders cancelled with this order
        done = ana.sql_exec("UPDATE production.work_order SET status = 'planned' WHERE number = $1 AND status = 'cancelled' "
                            "AND sales_order_id = $2", n, o["id"])
        (restored if done else kept).append(f"ordem de produção {n}")
    if kept:
        ana.table([{"documento": d, "situação": "mudou depois do cancelamento: ficou como está"} for d in kept],
                  title="Não restaurados")
    ana.log(f"pedido {number} reaberto" + (f"; restaurados: {', '.join(restored)}" if restored else ""))
    return {"number": number, "status": "OPEN", "restored": restored, "kept": kept}
