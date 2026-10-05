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
    # Spec 015: what already left at shipment (stock_out_on = shipment) is not taken again; freight
    # charged on the shipments goes into the invoice.
    shipped = {r["product_id"]: r["q"] for r in ana.sql(
        "SELECT l.product_id, sum(l.quantity) AS q FROM logistics.shipment_line l JOIN logistics.shipment s ON s.id = l.shipment_id "
        "WHERE s.sales_order_id = $1 AND s.stock_moved AND s.status NOT IN ('returned', 'cancelled') GROUP BY 1", order["id"])}
    freight = ana.sql_value("SELECT COALESCE(sum(freight_charged), 0) FROM logistics.shipment WHERE sales_order_id = $1 "
                            "AND status NOT IN ('returned', 'cancelled')", order["id"])
    items = [{**i, "quantity": i["quantity"] - shipped.get(i["product_id"], 0)} for i in items]
    goods = [i for i in items if i["kind"] == "goods" and i["quantity"] > 0]
    if goods:
        # Ordered locks on the products (one statement): prevents races and deadlocks.
        ana.sql("SELECT id FROM base.product WHERE id = ANY($1) ORDER BY id FOR UPDATE", [i["product_id"] for i in goods])
        balances = {r["product_id"]: r["balance"] for r in ana.sql(
            "SELECT product_id, sum(quantity) AS balance FROM inventory.stock_movement "
            "WHERE product_id = ANY($1) AND warehouse_id = $2 GROUP BY product_id",
            [i["product_id"] for i in goods], order["warehouse_id"])}
        for item in goods:
            balance = balances.get(item["product_id"], 0)
            if balance < item["quantity"]:
                raise ana.Error("INSUFFICIENT_STOCK",
                                f"{item['code']}: saldo {balance}, necessário {item['quantity']}",
                                {"product": item["code"], "balance": balance, "required": item["quantity"]})

    ana.sql_batch(
        "INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, created_by) "
        "VALUES ($1, $2, $3, 'out', $4, $5)",
        [[i["product_id"], order["warehouse_id"], -i["quantity"], document, ana.context.user] for i in goods])

    # Spec 027: revenue goes to the order's cost center (or the warehouse's; the database falls back to the company's).
    cc = ana.sql_value("SELECT COALESCE(o.cost_center, w.cost_center) FROM sales.sales_order o "
                       "JOIN inventory.warehouse w ON w.id = o.warehouse_id WHERE o.id = $1", order["id"])
    ana.sql("SELECT set_config('ana.cost_center', $1, true)", cc or "")
    entry = ana.sql_value(
        "INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
        f"Venda pedido {number}", document, ana.context.user)
    ana.sql_batch(
        "INSERT INTO finance.journal_line (entry_id, account, debit, credit) "
        "VALUES ($1, finance.account_for($2), $3, $4)",
        [[entry, "customers", order["total"] + freight, 0], [entry, "sales_revenue", 0, order["total"] + freight]])

    due = datetime.date.today() + datetime.timedelta(days=payment_days)
    bill = ana.sql_value(
        "INSERT INTO finance.bill (kind, party_id, document, due_date, amount, entry_id) "
        "VALUES ('receivable', $1, $2, $3, $4, $5) RETURNING id",
        order["customer_id"], document, due, order["total"] + freight, entry)

    ana.sql_exec("UPDATE sales.sales_order SET status = 'INVOICED', invoiced_at = now() WHERE id = $1",
                 order["id"])
    ana.log(f"pedido {number} faturado: {money(order['total'])}, vencimento {due}")
    return {"number": number, "total": order["total"] + freight, "freight": freight, "bill": bill, "entry": entry, "due_date": due}
