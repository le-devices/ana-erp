# ana:description Libera os pedidos retidos ou aguardando compra/produção quando o estoque chega
# ana:role admin
# ana:category Vendas/Atendimento
"""Spec 041 (RF-041-06). Runs by itself (schedule) and right after receipts and production deliveries; the
oldest order is served first. A freed order goes back to "pode expedir" and its sales flow moves on."""

from ana_lib.sales import fulfillment

PARAMS = {"orders": {"type": "list", "label": "pedidos (vazio = todos os que esperam)"}}


def main(orders=None):
    freed = fulfillment.release(orders)
    if freed:
        ana.log(f"{len(freed)} pedido(s) liberado(s): {', '.join(map(str, freed))}")
    return {"released": freed}
