# ana:description Fatura horas aprovadas, despesas refaturáveis e marcos concluídos
# ana:exposed yes
# ana:command invoiceproject
# ana:category Projetos/Faturamento e custos
"""Service invoice in a single execution transaction (RF-008-12).

Locks the project (RNF-008-03): concurrent invoicing never bills twice.
Accounts come from finance.default_account (P13).
"""

import datetime
from decimal import Decimal, ROUND_HALF_UP

from ana_lib.projects import access
from ana_lib.tax import engine
from ana_lib.util.format import money
from ana_lib.util.pdf import Pdf, company as letterhead_company

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto", "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "through": {"type": "date", "label": "até a data"},
    "payment_days": {"type": "int", "default": 30, "label": "prazo de pagamento (dias)"},
}

CENT = Decimal("0.01")


def cents(v):
    return Decimal(v).quantize(CENT, rounding=ROUND_HALF_UP)


def main(project, through=None, payment_days=30):
    p = access.project(project, lock=True)
    access.require_manager(p)
    through = through or datetime.date.today()
    # Spec 009 (D9): the customer's rules before invoicing; they may refuse or adjust the date and the term.
    adj = ana.extend("before_invoice_project", {"project": p["code"], "through": through, "payment_days": payment_days})
    through = datetime.date.fromisoformat(str(adj.get("through") or through)[:10])
    payment_days = int(adj.get("payment_days") or payment_days)

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
    # Spec 049: every tax comes from the engine (rules with validity, the Simples, withholdings) — never from here.
    try:
        calc = engine.calculate({"operation": "service_sale", "date": datetime.date.today(), "recipient": p["customer_id"],
                                 "contract": p["code"],
                                 "items": [{"description": l[1], "quantity": l[2], "unit_price": l[3], "amount": l[4]}
                                           for l in lines]})
    except engine.TaxError as e:
        raise ana.Error(e.code, f"impostos da fatura: {e.message}") from None
    withheld_total = calc["totals"]["withheld"]
    tax = withheld_total if withheld_total > 0 else calc["totals"]["amount"]
    tax_rate = (tax / total).quantize(Decimal("0.0001")) if total else Decimal(0)
    withheld = withheld_total > 0
    net = calc["net"]
    if net <= 0:
        raise ana.Error("NET_NOT_POSITIVE", f"as retenções ({money(withheld_total)}) consomem a fatura inteira ({money(total)})")

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
    # Spec 027: the project's cost center (the database falls back to the company's).
    ana.sql("SELECT set_config('ana.cost_center', $1, true)", p.get("cost_center") or "")
    entry = ana.sql_value(
        "INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
        f"Fatura de serviços {inv['number']} — projeto {p['code']}", document, ana.context.user)
    journal = [[entry, finance_account("customers"), net, 0], [entry, finance_account("service_revenue"), 0, total]]
    journal += [[entry, engine.account(x["account"]), x["debit"], x["credit"]] for x in calc["postings"]]
    ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit) VALUES ($1, $2, $3, $4)", journal)
    bill = ana.sql_value(
        "INSERT INTO finance.bill (kind, party_id, document, due_date, amount, entry_id) "
        "VALUES ('receivable', $1, $2, $3, $4, $5) RETURNING id",
        p["customer_id"], document, datetime.date.today() + datetime.timedelta(days=payment_days), net, entry)
    calc_id = engine.save(calc, "project_invoice", inv["number"])                               # RF-049-11
    ana.sql_exec("UPDATE projects.invoice SET bill_id = $2, entry_id = $3, tax_calculation_id = $4 WHERE id = $1",
                 inv["id"], bill, entry, calc_id)

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
    pdf = store_pdf(p, inv["number"], lines, total, calc, net, payment_days)
    result = {"number": inv["number"], "total": total, "service_tax": tax, "withheld": withheld,
              "net_amount": net, "bill": bill, "entry": entry, "lines": len(lines), "pdf": pdf,
              "taxes": [{"tax": t["tax"], "name": t["name"], "amount": t.get("amount", Decimal(0)),
                         "withheld": t.get("withheld", Decimal(0)), "charged": t.get("charged", Decimal(0))}
                        for t in calc["taxes"]],
              "tax_calculation": calc_id}
    ana.extend("after_invoice_project", {**result, "project": p["code"]})
    return result


def finance_account(key):
    return ana.sql_value("SELECT finance.account_for($1)", key)


def store_pdf(p, number, lines, total, calc, net, payment_days):
    """Spec 016 (CA-016-05): the invoice as PDF in the customer's folder (Faturas is shared
    with the customer's portal accounts). A storage problem never undoes the invoice."""
    company = letterhead_company()
    customer = ana.sql_one("SELECT name, tax_id FROM base.party WHERE id = $1", p["customer_id"])
    doc = Pdf(title=f"Fatura {number}")
    doc.letterhead(company)                                                                  # spec 009 (D11)
    doc.text(400, 790, f"Fatura nº {number}", size=12, bold=True)
    doc.text(400, 774, f"Emissão {datetime.date.today():%d/%m/%Y}", size=9)
    doc.text(50, 745, f"Cliente: {customer['name']}" + (f" — {customer['tax_id']}" if customer.get("tax_id") else ""), size=10)
    doc.text(50, 730, f"Projeto: {p['code']} — {p['name']}", size=10)
    y = doc.table(50, 700, ["Descrição", "Qtd", "Unitário", "Valor"],
                  [[l[1], l[2], money(l[3]), money(l[4])] for l in lines], widths=[300, 50, 80, 80])
    y -= 10
    doc.line(50, y, 560, y)
    doc.text(380, y - 16, "Total", bold=True)
    doc.text(480, y - 16, money(total), bold=True)
    charged = [t for t in calc["taxes"] if t.get("charged")]
    for t in charged:                                                                        # spec 049: added to the price
        y -= 14
        doc.text(300, y - 16, f"{t['name']} (acrescido)")
        doc.text(480, y - 16, money(t["charged"]))
    retained = [t for t in calc["taxes"] if t.get("withheld")]
    for t in retained:                                                                       # spec 049: one line per tax
        y -= 14
        doc.text(300, y - 16, f"{t['name']} retido")
        doc.text(480, y - 16, money(t["withheld"]))
    if retained or charged:
        y -= 14
        doc.text(380, y - 16, "Líquido a pagar", bold=True)
        doc.text(480, y - 16, money(net), bold=True)
    y -= 16
    venc = datetime.date.today() + datetime.timedelta(days=payment_days)
    doc.text(50, y - 40, f"Vencimento: {venc:%d/%m/%Y}", size=10)
    try:
        r = ana.files.publish("bill", p["customer_id"], f"Fatura {number}.pdf", doc.build(),
                              comment=f"Fatura de serviços {number} — projeto {p['code']}")
        return r["file"]
    except ana.Error as e:
        ana.log(f"fatura {number} sem PDF no repositório: {e.message}", "warning")
        return None
