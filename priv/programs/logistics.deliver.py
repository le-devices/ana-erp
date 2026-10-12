# ana:description Registra a entrega (comprovante) ou a devolução da expedição pela transportadora
# ana:exposed yes
"""RF-015-02. returned: the goods come back to the warehouse (when they had left at shipment)."""

from decimal import Decimal

from ana_lib.logistics import common
from ana_lib.docs import pdfs

PARAMS = {
    "shipment": {"type": "int", "required": True, "label": "expedição"},
    "received_by": {"type": "str", "label": "recebido por (comprovante)"},
    "returned": {"type": "bool", "default": False, "label": "voltou (não entregue)"},
}


def main(shipment, received_by=None, returned=False):
    s = ana.sql_one("SELECT s.id, s.number, s.status, s.stock_moved, o.warehouse_id FROM logistics.shipment s "
                    "JOIN sales.sales_order o ON o.id = s.sales_order_id WHERE s.number = $1 FOR UPDATE OF s", shipment)
    if not s:
        raise ana.Error("SHIPMENT_NOT_FOUND", f"expedição {shipment} não encontrada")
    if s["status"] != "shipped":
        raise ana.Error("INVALID_STATE", f"expedição {shipment} não está despachada")
    if returned:
        if s["stock_moved"]:
            back = {}
            for l in ana.sql("SELECT product_id, quantity FROM logistics.shipment_line WHERE shipment_id = $1", s["id"]):
                back[l["product_id"]] = back.get(l["product_id"], Decimal(0)) + l["quantity"]
            common.put_stock(s["warehouse_id"], back, f"EXP-{s['number']}-VOLTA", "customer_return")
        ana.sql_exec("UPDATE logistics.shipment SET status = 'returned' WHERE id = $1", s["id"])
        return {"shipment": s["number"], "status": "returned"}
    if not received_by or len(received_by.strip()) < 2:
        raise ana.Error("INVALID_PARAMETER", "informe quem recebeu")
    ana.sql_exec("UPDATE logistics.shipment SET status = 'delivered', delivered_at = now(), received_by = $2 WHERE id = $1",
                 s["id"], received_by.strip())
    pdfs.publish_quietly("shipment", s["number"])      # spec 037: delivery receipt
    return {"shipment": s["number"], "status": "delivered"}
