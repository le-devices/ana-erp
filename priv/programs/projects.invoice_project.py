# ana:description Fatura horas aprovadas, despesas refaturáveis e marcos concluídos
# ana:exposed yes
# ana:command invoiceproject
"""Service invoice in a single execution transaction (RF-008-12).

Locks the project (RNF-008-03): concurrent invoicing never bills twice.
Accounts come from finance.default_account (P13).
"""

import datetime
from decimal import Decimal, ROUND_HALF_UP

from ana_lib.projects import access
from ana_lib.util.format import money

PARAMS = {
    "project": {"type": "str", "required": True},
    "through": {"type": "date"},
    "payment_days": {"type": "int", "default": 30},
}

CENT = Decimal("0.01")


def cents(v):
    return Decimal(v).quantize(CENT, rounding=ROUND_HALF_UP)


def main(project, through=None, payment_days=30):
    p = access.project(project, lock=True)
    access.require_manager(p)
    through = through or datetime.date.today()

    hours = ana.sql(
        "SELECT t.profile, rp.description, t.hourly_rate, sum(t.hours) AS hours, array_agg(t.id) AS ids "
        "FROM projects.time_entry t JOIN projects.rate_profile rp ON rp.code = t.profile "
        "WHERE t.project_id = $1 AND t.status = 'approved' AND t.billable AND t.invoice_id IS NULL "
        "  AND t.entry_date <= $2 "
        "GROUP BY t.profile, rp.description, t.hourly_rate ORDER BY t.profile", p["id"], through)
    expenses = ana.sql(
        "SELECT id, kind, description, quantity, unit_cost, markup_pct FROM projects.expense "
        "WHERE project_id = $1 AND status = 'posted' AND rebillable AND expense_date <= $2 ORDER BY id",
        p["id"], through)
    milestones = ana.sql(
        "SELECT id, description, amount FROM projects.milestone "
        "WHERE project_id = $1 AND status = 'completed' ORDER BY id", p["id"])

    lines = []
    for h in hours:
        lines.append(("hours", f"Horas — {h['description']}", h["hours"], h["hourly_rate"],
                      cents(h["hours"] * h["hourly_rate"])))
    for e in expenses:
        factor = 1 + e["markup_pct"] / 100
        lines.append(("expense", f"{e['kind']}: {e['description']}", e["quantity"],
                      cents(e["unit_cost"] * factor), cents(e["quantity"] * e["unit_cost"] * factor)))
    for m in milestones:
        lines.append(("milestone", m["description"], Decimal(1), m["amount"], m["amount"]))
    if not lines:
        raise ana.Error("NOTHING_TO_INVOICE", f"nada a faturar no projeto {p['code']} até {through}")

    total = sum((l[4] for l in lines), Decimal(0))
    tax_rate = p["service_tax_rate"]
    tax = cents(total * tax_rate)
    withheld = p["service_tax_withheld"] and tax > 0
    net = total - tax if withheld else total

    inv = ana.sql_one(
        "INSERT INTO projects.invoice (project_id, customer_id, through_date, total, service_tax_rate, "
        "  service_tax_amount, service_tax_withheld, net_amount, created_by) "
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id, number",
        p["id"], p["customer_id"], through, total, tax_rate, tax, withheld, net, ana.context.user)
    ana.sql_batch(
        "INSERT INTO projects.invoice_line (invoice_id, line, source, description, quantity, unit_price, amount) "
        "VALUES ($1, $2, $3, $4, $5, $6, $7)",
        [[inv["id"], n, *l] for n, l in enumerate(lines, start=1)])

    document = f"INV-{inv['number']}"
    entry = ana.sql_value(
        "INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
        f"Fatura de serviços {inv['number']} — projeto {p['code']}", document, ana.context.user)
    journal = [[entry, "customers", net, 0], [entry, "service_revenue", 0, total]]
    if withheld:
        journal.append([entry, "service_tax_withheld", tax, 0])
    ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit) "
                  "VALUES ($1, finance.account_for($2), $3, $4)", journal)
    bill = ana.sql_value(
        "INSERT INTO finance.bill (kind, party_id, document, due_date, amount, entry_id) "
        "VALUES ('receivable', $1, $2, $3, $4, $5) RETURNING id",
        p["customer_id"], document, datetime.date.today() + datetime.timedelta(days=payment_days), net, entry)
    ana.sql_exec("UPDATE projects.invoice SET bill_id = $2, entry_id = $3 WHERE id = $1", inv["id"], bill, entry)

    ids = [i for h in hours for i in h["ids"]]
    if ids:
        ana.sql_exec("UPDATE projects.time_entry SET status = 'invoiced', invoice_id = $2 WHERE id = ANY($1)",
                     ids, inv["id"])
    if expenses:
        ana.sql_exec("UPDATE projects.expense SET status = 'invoiced', invoice_id = $2 WHERE id = ANY($1)",
                     [e["id"] for e in expenses], inv["id"])
    if milestones:
        ana.sql_exec("UPDATE projects.milestone SET status = 'invoiced', invoice_id = $2 WHERE id = ANY($1)",
                     [m["id"] for m in milestones], inv["id"])

    ana.table([{"origem": l[0], "descrição": l[1], "qtd": l[2], "unitário": money(l[3]), "valor": money(l[4])}
               for l in lines], title=f"Fatura {inv['number']}")
    return {"number": inv["number"], "total": total, "service_tax": tax, "withheld": withheld,
            "net_amount": net, "bill": bill, "entry": entry, "lines": len(lines)}
