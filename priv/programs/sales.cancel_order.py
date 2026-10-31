# ana:description Cancela pedido ainda não faturado (e o suprimento vinculado que ainda não foi adiante)
# ana:exposed yes
# ana:command cancel
# ana:category Vendas/Pedidos
"""Spec 041 (D6, RF-041-09, CA-041-07): cancelling the order cancels the linked purchase requests not yet sent
to the supplier and the work orders not yet released; what is already ordered or in production becomes free
stock when it arrives. "Simular" shows that effect before confirming (nothing changes)."""

from ana_lib.sales import fulfillment as F
from ana_lib.util import validation as v
from ana_lib.util.format import status_text

PARAMS = {
    "number": {"type": "int", "required": True, "label": "pedido", "lookup": {"program": "sales.lookup", "params": {"kind": "orders"}}},
    "simulate": {"type": "bool", "simulate": True, "label": "ver o efeito antes (não grava)"},
}


def main(number, simulate=False):
    # A simulation runs read-only (spec 020): it reads, it does not lock.
    o = ana.sql_one("SELECT id, status FROM sales.sales_order WHERE number = $1" + ("" if simulate else " FOR UPDATE"), number)
    v.require(o, "ORDER_NOT_FOUND", f"pedido {number} não encontrado")
    v.require(o["status"] == "OPEN", "ORDER_NOT_OPEN", f"pedido {number} está {status_text(o['status'])}")
    effect = F.cancel_effect(o["id"])
    if effect:
        ana.table([{"documento": f"{kind} {n}", "situação": status, "ao cancelar o pedido": what} for kind, n, status, what, _ in effect],
                  title="Efeito no suprimento vinculado" + (" (simulação)" if simulate else ""))
    if simulate:
        return {"number": number, "simulated": True, "effect": [{"kind": k, "number": n, "cancel": c} for k, n, _, _, c in effect]}
    ana.sql_exec("UPDATE sales.sales_order SET status = 'CANCELLED' WHERE id = $1", o["id"])
    reason = f"pedido de venda {number} cancelado"
    for kind, n, _, _, cancel in effect:
        if not cancel:
            continue
        if kind == "ordem de produção":
            # ana:lint-ok sql_in_loop — the few work orders made for this order
            ana.call("production.cancel_order", order=n, reason=reason)
        else:
            ana.sql_exec("UPDATE supply.purchase_request SET status = 'cancelled', rejection_reason = $2 WHERE number = $1 "
                         "AND status IN ('draft', 'submitted', 'approved')", n, reason)
    return {"number": number, "status": "CANCELLED", "supply_cancelled": [n for _, n, _, _, c in effect if c],
            "supply_kept": [n for _, n, _, _, c in effect if not c]}
