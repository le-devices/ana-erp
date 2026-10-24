# ana:description Cancela pedido ainda não faturado
# ana:exposed yes
# ana:command cancel
# ana:category Vendas/Pedidos
from ana_lib.util import validation as v

PARAMS = {
    "number": {"type": "int", "required": True, "label": "pedido", "lookup": {"program": "sales.lookup", "params": {"kind": "orders"}}},
}


def main(number):
    status = ana.sql_value("SELECT status FROM sales.sales_order WHERE number = $1 FOR UPDATE", number)
    v.require(status, "ORDER_NOT_FOUND", f"pedido {number} não encontrado")
    v.require(status == "OPEN", "ORDER_NOT_OPEN", f"pedido {number} está {status}")
    ana.sql_exec("UPDATE sales.sales_order SET status = 'CANCELLED' WHERE number = $1", number)
    return {"number": number, "status": "CANCELLED"}
