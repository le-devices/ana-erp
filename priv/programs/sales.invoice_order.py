# ana:description Fatura pedido: baixa estoque, gera título e lançamento contábil
# ana:exposed yes
# ana:command invoice
"""Invoicing in a single execution transaction (RF-006-04, RF-008-01/02).

Locks the order and, ordered by product, the product rows (RNF-006-01) so that
concurrent invoicing never drives a balance negative. Services skip stock.
"""

import datetime

from ana_lib.finance import invoice_pdf, terms
from ana_lib.util import validation as v
from ana_lib.util.format import money

PARAMS = {
    "number": {"type": "int", "required": True, "label": "pedido", "lookup": {"program": "sales.lookup", "params": {"kind": "orders"}}},
    "payment_days": {"type": "int", "default": 30, "label": "prazo em dias (só sem condição de pagamento)"},
}


def main(number, payment_days=30):
    order = ana.sql_one(
        "SELECT id, number, customer_id, warehouse_id, status, total, payment_term "
        "FROM sales.sales_order WHERE number = $1 FOR UPDATE", number)
    v.require(order, "ORDER_NOT_FOUND", f"pedido {number} não encontrado")
    v.require(order["status"] == "OPEN", "ORDER_NOT_OPEN", f"pedido {number} está {order['status']}")
    terms.check_credit(order["customer_id"], 0, "invoice", order["id"])   # spec 031

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

    # Spec 027: revenue goes to the order's cost center (or the warehouse's; the database falls back to the company's).
    # Set before the stock leaves: the database posts the cost of goods sold to the same cost center (spec 038).
    cc = ana.sql_value("SELECT COALESCE(o.cost_center, w.cost_center) FROM sales.sales_order o "
                       "JOIN inventory.warehouse w ON w.id = o.warehouse_id WHERE o.id = $1", order["id"])
    ana.sql("SELECT set_config('ana.cost_center', $1, true)", cc or "")
    ana.sql_batch(
        "INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, created_by, reason) "
        "VALUES ($1, $2, $3, 'out', $4, $5, 'sale')",
        [[i["product_id"], order["warehouse_id"], -i["quantity"], document, ana.context.user] for i in goods])
    term0 = terms.term_for(order["customer_id"], order["payment_term"])
    gross = terms.adjusted(order["total"] + freight, term0) if term0 else order["total"] + freight
    entry = ana.sql_value(
        "INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
        f"Venda pedido {number}", document, ana.context.user)
    ana.sql_batch(
        "INSERT INTO finance.journal_line (entry_id, account, debit, credit) "
        "VALUES ($1, finance.account_for($2), $3, $4)",
        # Spec 038: the freight charged to the customer has its own revenue account.
        [l for l in [[entry, "customers", gross, 0], [entry, "sales_revenue", 0, gross - freight],
                     [entry, "freight_revenue", 0, freight]] if l[2] or l[3]])

    # Spec 031: one bill per installment of the order's term (else the customer's / the policy's,
    # else a single bill due in payment_days); a gateway connector on the term issues the charges.
    term = term0
    if term:
        sched = terms.schedule(gross, term)
    else:
        sched = [(1, datetime.date.today() + datetime.timedelta(days=payment_days), gross)]
    n = len(sched)
    bills = ana.sql(
        "INSERT INTO finance.bill (kind, party_id, document, due_date, amount, entry_id, installment, installments, payment_method, payment_term) "
        "SELECT 'receivable', $1, CASE WHEN $7 = 1 THEN $2 ELSE $2 || '/' || k END, d, a::numeric, $3, k, $7, $4, $5 "
        "FROM unnest($6::int[], $8::date[], $9::text[]) AS x(k, d, a) RETURNING id",
        order["customer_id"], document, entry, term and term["method"], term and term["code"], [k for k, _, _ in sched], n,
        [d for _, d, _ in sched], [str(a) for _, _, a in sched])
    bill = bills[0]["id"]
    due = sched[0][1]
    charges = []
    if term and term["connector"] and term["method"] in ("pix", "boleto", "credit_card"):
        method = {"pix": "pix", "boleto": "boleto", "credit_card": "card_link"}[term["method"]]
        for b in bills:
            # ana:lint-ok sql_in_loop — one charge request per installment (queued in the outbox)
            charges.append(ana.call("finance.create_charge", bill=b["id"], connector=term["connector"], method=method)["charge"])

    ana.sql_exec("UPDATE sales.sales_order SET status = 'INVOICED', invoiced_at = now() WHERE id = $1",
                 order["id"])
    ana.log(f"pedido {number} faturado: {money(order['total'])}, vencimento {due}")
    pdf = invoice_pdf.store(document)          # spec 035: the invoice PDF in the customer's folder (portal sees it)
    return {"number": number, "total": gross, "freight": freight, "bill": bill, "bills": [b["id"] for b in bills],
            "installments": n, "entry": entry, "due_date": due, "charges": charges, "pdf": pdf}
