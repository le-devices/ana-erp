# ana:description Devolução de cliente: entrada no estoque (ou quarentena) e crédito ao cliente
# ana:exposed yes
# ana:command devolucao
"""RF-015-04. D sales_returns / C customer_credits and a payable bill to the customer (the credit,
control account customer_credits); goods enter the chosen warehouse, or QUARENTENA to be inspected,
at the average cost (spec 038: the database posts D inventory / C cost of goods sold)."""

import datetime
from decimal import Decimal, ROUND_HALF_UP

from ana_lib.logistics import common

PARAMS = {
    "customer": {"type": "int", "required": True, "label": "cliente", "lookup": {"program": "sales.lookup", "params": {"kind": "customers"}}},
    "items": {"type": "list", "required": True, "label": "itens devolvidos", "add_label": "Adicionar item", "columns": {
        "product": {"type": "str", "required": True, "label": "item", "lookup": {"program": "supply.lookup", "params": {"kind": "products"}}},
        "quantity": {"type": "decimal", "required": True, "default": 1, "label": "quantidade"},
        "price": {"type": "decimal", "required": True, "label": "valor unitário do crédito"}}},
    "reason": {"type": "str", "required": True, "label": "motivo"},
    "order": {"type": "int", "label": "pedido de origem", "lookup": {"program": "sales.lookup", "params": {"kind": "invoiced"}, "depends": ["customer"]}},
    "warehouse": {"type": "str", "default": "CENTRAL", "label": "depósito", "lookup": {"program": "logistics.lookup", "params": {"kind": "warehouses"}}},
    "quarantine": {"type": "bool", "default": False, "label": "para inspeção (quarentena)"},
}


def main(customer, items, reason, order=None, warehouse="CENTRAL", quarantine=False):
    party = ana.sql_one("SELECT id, name FROM base.party WHERE id = $1 AND kind IN ('customer', 'both')", customer)
    if not party:
        raise ana.Error("CUSTOMER_NOT_FOUND", f"cliente {customer} não encontrado")
    wh = common.warehouse("QUARENTENA" if quarantine else warehouse)
    so = None
    if order:
        so = ana.sql_one("SELECT id, cost_center FROM sales.sales_order WHERE number = $1 AND customer_id = $2", order, customer)
        if not so:
            raise ana.Error("ORDER_NOT_FOUND", f"pedido {order} não é deste cliente")
    prods = common.products(i.get("product", "") for i in items)
    lines = []
    for n, i in enumerate(items, start=1):
        p = prods[str(i["product"]).strip().upper()]
        q = Decimal(str(i["quantity"]))
        price = Decimal(str(i["price"])) if i.get("price") is not None else p["price"]
        if q <= 0 or price < 0:
            raise ana.Error("INVALID_VALUE", f"item {n}: quantidade e preço válidos")
        lines.append((n, p, q, price))
    total = sum((q * pr for _, _, q, pr in lines), Decimal(0)).quantize(Decimal("0.01"), ROUND_HALF_UP)
    r = ana.sql_one("INSERT INTO logistics.customer_return (customer_id, sales_order_id, warehouse_id, reason, total, created_by) "
                    "VALUES ($1, $2, $3, $4, $5, $6) RETURNING id, number", customer, so and so["id"], wh["id"], reason, total,
                    ana.context.user)
    ana.sql_batch("INSERT INTO logistics.return_line (return_id, line, product_id, quantity, unit_price) VALUES ($1, $2, $3, $4, $5)",
                  [[r["id"], n, p["id"], q, pr] for n, p, q, pr in lines])
    ana.sql("SELECT set_config('ana.cost_center', $1, true)", (so and so["cost_center"]) or "")
    common.put_stock(wh["id"], {p["id"]: q for _, p, q, _ in lines if p["kind"] == "goods"}, f"DEV-{r['number']}", "customer_return")
    entry = bill = None
    if total > 0:
        ana.sql("SELECT set_config('ana.cost_center', $1, true)", (so and so["cost_center"]) or "")
        entry = ana.sql_value("INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
                              f"Devolução de {party['name']}: {reason}"[:200], f"DEV-{r['number']}", ana.context.user)
        ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit) VALUES ($1, finance.account_for($2), $3, $4)",
                      [[entry, "sales_returns", total, 0], [entry, "customer_credits", 0, total]])
        bill = ana.sql_value("INSERT INTO finance.bill (kind, party_id, document, due_date, amount, entry_id, account) "
                             "VALUES ('payable', $1, $2, $3, $4, $5, finance.account_for('customer_credits')) RETURNING id",
                             customer, f"DEV-{r['number']}",
                             datetime.date.today() + datetime.timedelta(days=30), total, entry)
        ana.sql_exec("UPDATE logistics.customer_return SET entry_id = $2, bill_id = $3 WHERE id = $1", r["id"], entry, bill)
    return {"return": r["number"], "total": total, "warehouse": wh["code"], "credit_bill": bill}
