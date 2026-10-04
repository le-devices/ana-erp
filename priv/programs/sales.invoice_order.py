# ana:description Fatura pedido: baixa estoque, gera título e lançamento contábil
# ana:exposed yes
# ana:command invoice
"""Invoicing in a single execution transaction (RF-006-04, RF-008-01/02).

Locks the order and, ordered by product, the product rows (RNF-006-01) so that
concurrent invoicing never drives a balance negative. Services skip stock.
"""

import datetime

from ana_lib.util import validation as v
from ana_lib.util.format import money

PARAMS = {
    "number": {"type": "int", "required": True},
    "payment_days": {"type": "int", "default": 30},
}


def main(number, payment_days=30):
    order = ana.sql_one(
        "SELECT id, number, customer_id, warehouse_id, status, total "
        "FROM sales.sales_order WHERE number = $1 FOR UPDATE", number)
    v.require(order, "ORDER_NOT_FOUND", f"pedido {number} não encontrado")
    v.require(order["status"] == "OPEN", "ORDER_NOT_OPEN", f"pedido {number} está {order['status']}")

    items = ana.sql(
        "SELECT i.product_id, p.code, p.kind, sum(i.quantity) AS quantity "
        "FROM sales.sales_order_item i JOIN base.product p ON p.id = i.product_id "
        "WHERE i.order_id = $1 GROUP BY i.product_id, p.code, p.kind ORDER BY i.product_id", order["id"])
    v.require(items, "EMPTY_ORDER", f"pedido {number} não tem itens")

    document = f"ORD-{number}"
    goods = [i for i in items if i["kind"] == "goods"]
    for item in goods:
        # Ordered lock per product: prevents races and deadlocks.
        ana.sql("SELECT id FROM base.product WHERE id = $1 FOR UPDATE", item["product_id"])
        balance = ana.sql_value(
            "SELECT COALESCE(sum(quantity), 0) FROM inventory.stock_movement "
            "WHERE product_id = $1 AND warehouse_id = $2", item["product_id"], order["warehouse_id"])
        if balance < item["quantity"]:
            raise ana.Error("INSUFFICIENT_STOCK",
                            f"{item['code']}: saldo {balance}, necessário {item['quantity']}",
                            {"product": item["code"], "balance": balance, "required": item["quantity"]})

    ana.sql_batch(
        "INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, created_by) "
        "VALUES ($1, $2, $3, 'out', $4, $5)",
        [[i["product_id"], order["warehouse_id"], -i["quantity"], document, ana.context.user] for i in goods])

    entry = ana.sql_value(
        "INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
        f"Venda pedido {number}", document, ana.context.user)
    ana.sql_batch(
        "INSERT INTO finance.journal_line (entry_id, account, debit, credit) "
        "VALUES ($1, finance.account_for($2), $3, $4)",
        [[entry, "customers", order["total"], 0], [entry, "sales_revenue", 0, order["total"]]])

    due = datetime.date.today() + datetime.timedelta(days=payment_days)
    bill = ana.sql_value(
        "INSERT INTO finance.bill (kind, party_id, document, due_date, amount, entry_id) "
        "VALUES ('receivable', $1, $2, $3, $4, $5) RETURNING id",
        order["customer_id"], document, due, order["total"], entry)

    ana.sql_exec("UPDATE sales.sales_order SET status = 'INVOICED', invoiced_at = now() WHERE id = $1",
                 order["id"])
    ana.log(f"pedido {number} faturado: {money(order['total'])}, vencimento {due}")
    return {"number": number, "total": order["total"], "bill": bill, "entry": entry, "due_date": due}
