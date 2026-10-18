# ana:description PDF da fatura de pedido ou de OS: itens, parcelas, vencimentos e dados de pagamento
# ana:kind library
"""Spec 035 (follow-up). One PDF per invoice document ("ORD-12", "OS-5"), with all its
installments, kept in the customer's folder "Faturas" (shared with the customer's portal
accounts, spec 016). store() never undoes the invoice when the repository fails."""

import datetime

from ana_lib.docs import common as docs
from ana_lib.util.format import compact, money
from ana_lib.util.pdf import Pdf, company as letterhead_company


def base(document):
    return str(document).split("/")[0]


def file_name(document):
    return f"Fatura {base(document)}.pdf"


def build(document):
    """(party_id, pdf bytes) of the invoice document."""
    doc_base = base(document)
    bills = ana.sql("SELECT b.id, b.party_id, b.document, b.issue_date, b.due_date, b.amount, b.status, b.installment, b.installments, "
                    "  t.name AS term, (SELECT c.digitable_line FROM finance.charge c WHERE c.bill_id = b.id AND c.status <> 'cancelled' "
                    "                   ORDER BY c.id DESC LIMIT 1) AS line, "
                    "  (SELECT COALESCE(c.qr_code, c.url) FROM finance.charge c WHERE c.bill_id = b.id AND c.status <> 'cancelled' "
                    "   ORDER BY c.id DESC LIMIT 1) AS pay "
                    "FROM finance.bill b LEFT JOIN finance.payment_term t ON t.code = b.payment_term "
                    "WHERE b.kind = 'receivable' AND (b.document = $1 OR b.document LIKE $1 || '/%') "
                    "ORDER BY b.installment NULLS FIRST, b.id", doc_base)
    if not bills:
        raise ana.Error("BILL_NOT_FOUND", f"fatura {doc_base} não encontrada")
    party = bills[0]["party_id"]
    company = letterhead_company()
    customer = ana.sql_one("SELECT name, tax_id, address, city, state FROM base.party WHERE id = $1", party)
    origin = docs.of_text(doc_base)
    items = []
    if origin and origin[0] == "order":
        items = [[f"{r['code']} — {r['description']}", compact(r["quantity"]), money(r["price"]), money(r["amount"])]
                 for r in ana.sql("SELECT p.code, p.description, i.quantity, i.price, i.amount FROM sales.sales_order_item i "
                                  "JOIN sales.sales_order o ON o.id = i.order_id JOIN base.product p ON p.id = i.product_id "
                                  "WHERE o.number = $1 ORDER BY i.line", int(origin[1]))]
    elif origin and origin[0] == "service_order":
        items = [[r["description"], compact(r["quantity"]), money(r["unit_price"]), money(r["amount"])]
                 for r in ana.sql("SELECT l.description, l.quantity, l.unit_price, l.amount FROM field.invoice_line l "
                                  "JOIN field.service_order o ON o.id = l.order_id WHERE o.number = $1 ORDER BY l.line", int(origin[1]))]
    pdf = Pdf(title=f"Fatura {doc_base}")
    pdf.letterhead(company, [f"{company.get('address') or ''} {company['city']}/{company.get('state') or ''}".strip()
                             if company.get("city") else None])                                    # spec 009 (D11)
    pdf.text(400, 790, f"Fatura {doc_base}", size=12, bold=True)
    pdf.text(400, 774, f"Emissão {bills[0]['issue_date']:%d/%m/%Y}", size=9)
    pdf.text(50, 735, f"Cliente: {customer['name']}" + (f" — {customer['tax_id']}" if customer.get("tax_id") else ""), size=10)
    if customer.get("city"):
        pdf.text(50, 721, f"{customer.get('address') or ''} {customer['city']}/{customer.get('state') or ''}".strip(), size=9)
    if origin:
        pdf.text(50, 707, f"Referente a: {docs.KINDS[origin[0]].lower()} {origin[1]}", size=9)
    y = 685
    if items:
        y = pdf.table(50, y, ["Descrição", "Qtd", "Unitário", "Valor"], items, widths=[300, 50, 80, 80])
        y -= 18
    total = sum(b["amount"] for b in bills)
    pdf.text(50, y, "Parcelas" + (f" — {bills[0]['term']}" if bills[0]["term"] else ""), size=11, bold=True)
    y = pdf.table(50, y - 12, ["Parcela", "Vencimento", "Valor", "Situação"],
                  [[f"{b['installment']}/{b['installments']}" if b["installments"] else "única", f"{b['due_date']:%d/%m/%Y}",
                    money(b["amount"]), {"open": "em aberto", "settled": "paga", "cancelled": "cancelada"}.get(b["status"], b["status"])]
                   for b in bills], widths=[90, 110, 110, 110])
    y -= 10
    pdf.line(50, y, 560, y)
    pdf.text(380, y - 16, "Total", bold=True)
    pdf.text(480, y - 16, money(total), bold=True)
    y -= 44
    for b in bills:
        if b["line"] or b["pay"]:
            pdf.text(50, y, f"Pagamento da parcela {b['installment'] or 1}: {b['line'] or b['pay']}"[:110], size=8)
            y -= 12
    pdf.text(50, 50, f"Gerado pelo ANA ERP em {datetime.datetime.now():%d/%m/%Y %H:%M}", size=7)
    return party, pdf.build()


def store(document):
    """File id of the stored PDF (new version when it exists), or None if the repository failed."""
    try:
        with ana.savepoint():           # a failure here rolls back only the PDF, never the invoice
            party, data = build(document)
            # Spec 037: published in the customer's folder for invoices (only that customer reaches it).
            r = ana.files.publish("bill", party, file_name(document), data, comment=f"Fatura {base(document)}")
            return r["file"]
    except ana.Error as e:
        ana.log(f"fatura {base(document)} sem PDF no repositório: {e.message}", "warning")
        return None


def find(party, document):
    """Id of the PDF already stored for the document, or None."""
    try:
        folder = ana.files.folder(entity=("party", int(party)), subfolder="Faturas", create=False)
        files = ana.files.list(folder)["files"]
    except ana.Error:
        return None
    name = file_name(document)
    return next((f["id"] for f in files if f["name"] == name), None)
