# ana:description Compras: aceite da nota do fornecedor (título, recebimentos a faturar e variação de preço)
# ana:kind library
"""Spec 038 (RF-038-10). Shared by supply.register_invoice and supply.invoices."""

import datetime

import ana
from ana_lib.finance import banking
from ana_lib.tax import engine as tax_engine


def accept(inv, user):
    i = ana.sql_one("SELECT i.*, o.number AS order_number FROM supply.supplier_invoice i JOIN supply.purchase_order o ON o.id = i.order_id "
                    "WHERE i.id = $1 FOR UPDATE OF i", inv)
    doc = f"NF-{i['number']}-OC-{i['order_number']}"
    entry = ana.sql_value("INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
                          f"Nota {i['number']} do fornecedor (ordem {i['order_number']})", doc, user)
    lines = [[entry, "@goods_received", i["expected"], 0]]
    if i["difference"] > 0:
        lines.append([entry, "@purchase_price_variance", i["difference"], 0])
    elif i["difference"] < 0:
        lines.append([entry, "@purchase_price_variance", 0, -i["difference"]])
    lines.append([entry, "@suppliers", 0, i["amount"]])
    ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit) VALUES ($1, finance.account_for(substr($2, 2)), $3, $4)", lines)
    # Spec 049 (D7, phase 3): credits of the taxes paid on the purchase, by the rules in force (none → nothing posted).
    try:
        calc = tax_engine.calculate({"operation": "purchase", "date": datetime.date.today(), "recipient": i["supplier_id"],
                                     "items": [{"description": f"nota {i['number']}", "amount": i["amount"]}]})
    except tax_engine.TaxError as e:
        raise ana.Error(e.code, f"impostos da nota {i['number']}: {e.message}") from None
    if calc["postings"]:
        ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit) VALUES ($1, $2, $3, $4)",
                      [[entry, tax_engine.account(x["account"]), x["debit"], x["credit"]] for x in calc["postings"]])
    if calc["taxes"]:
        tax_engine.save(calc, "supplier_invoice", str(inv))
    bill = ana.sql_value("INSERT INTO finance.bill (kind, party_id, document, due_date, amount, entry_id, account) "
                         "VALUES ('payable', $1, $2, $3, $4, $5, finance.account_for('suppliers')) RETURNING id",
                         i["supplier_id"], doc, i["due_date"], i["amount"], entry)
    ana.sql_exec("UPDATE supply.receipt SET bill_id = $2 WHERE id = ANY($1)", i["receipts"], bill)
    ana.sql_exec("UPDATE supply.supplier_invoice SET status = 'accepted', bill_id = $2, entry_id = $3, decided_by = $4, decided_at = now() "
                 "WHERE id = $1", inv, bill, entry, user)
    if banking.policy()["auto_offset"]:
        banking.offset(i["supplier_id"], user)
    return bill
