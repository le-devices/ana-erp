# ana:description PDFs dos documentos entregues a clientes e fornecedores (pedido, entrega, atendimento, recibo, extrato, ordem de compra)
# ana:kind library
"""Spec 037. Only the kinds in EXTERNAL have a PDF for partners; the core publishes them in the
partner's folder for that kind (closed list too) and refuses anything else. Internal documents
(entries, production orders, transfers, reports) have no builder here on purpose."""

import datetime

from ana_lib.finance import invoice_pdf
from ana_lib.util.format import compact, money
from ana_lib.util.pdf import Pdf, company as letterhead_company

STATUS = {"open": "em aberto", "settled": "pago", "cancelled": "cancelado"}


class Internal(Exception):
    pass


def _header(pdf, title, number, date, party, ref=None):
    company = letterhead_company()
    pdf.letterhead(company, [" · ".join(x for x in (company.get("phone"), company.get("email")) if x)])   # spec 009 (D11)
    pdf.text(360, 790, f"{title} {number}", size=12, bold=True)
    pdf.text(360, 776, f"Data {date:%d/%m/%Y}", size=9)
    p = ana.sql_one("SELECT name, tax_id, address, city, state FROM base.party WHERE id = $1", party)
    pdf.text(50, 738, f"{p['name']}" + (f" — {p['tax_id']}" if p.get("tax_id") else ""), size=10, bold=True)
    place = " ".join(x for x in (p.get("address"), f"{p['city']}/{p['state']}" if p.get("city") else None) if x)
    if place:
        pdf.text(50, 725, place, size=9)
    if ref:
        pdf.text(50, 712, ref, size=9)
    return 690


def _footer(pdf):
    pdf.text(50, 40, f"Documento gerado pelo ANA ERP em {datetime.datetime.now():%d/%m/%Y %H:%M}", size=7)


# ---------------------------------------------------------------- builders: (party, name, bytes)

def order(key):
    o = ana.sql_one("SELECT o.id, o.number, o.customer_id, o.order_date, o.total, o.notes, t.name AS term, w.code AS warehouse "
                    "FROM sales.sales_order o JOIN inventory.warehouse w ON w.id = o.warehouse_id "
                    "LEFT JOIN finance.payment_term t ON t.code = o.payment_term WHERE o.number = $1", int(key))
    if not o:
        raise ana.Error("DOCUMENT_NOT_FOUND", f"pedido {key} não encontrado")
    pdf = Pdf(title=f"Pedido {o['number']}")
    y = _header(pdf, "Pedido", o["number"], o["order_date"], o["customer_id"],
                f"Condição de pagamento: {o['term']}" if o["term"] else None)
    items = ana.sql("SELECT p.code, p.description, i.quantity, i.price, i.amount FROM sales.sales_order_item i "
                    "JOIN base.product p ON p.id = i.product_id WHERE i.order_id = $1 ORDER BY i.line", o["id"])
    y = pdf.table(50, y, ["Item", "Qtd", "Unitário", "Valor"],
                  [[f"{i['code']} — {i['description']}", compact(i["quantity"]), money(i["price"]), money(i["amount"])] for i in items],
                  widths=[300, 50, 80, 80])
    pdf.line(50, y - 6, 560, y - 6)
    pdf.text(380, y - 22, "Total", bold=True)
    pdf.text(480, y - 22, money(o["total"]), bold=True)
    if o["notes"]:
        pdf.text(50, y - 46, f"Observações: {o['notes']}"[:110], size=9)
    _footer(pdf)
    return o["customer_id"], f"Pedido {o['number']}.pdf", pdf.build()


def shipment(key):
    s = ana.sql_one("SELECT s.id, s.number, s.status, s.tracking, s.packages, s.weight_kg, s.shipped_at, s.delivered_at, s.received_by, "
                    "  o.number AS order_number, o.customer_id, c.name AS carrier, c.tracking_url "
                    "FROM logistics.shipment s JOIN sales.sales_order o ON o.id = s.sales_order_id "
                    "LEFT JOIN logistics.carrier c ON c.id = s.carrier_id WHERE s.number = $1", int(key))
    if not s:
        raise ana.Error("DOCUMENT_NOT_FOUND", f"expedição {key} não encontrada")
    pdf = Pdf(title=f"Entrega {s['number']}")
    when = (s["delivered_at"] or s["shipped_at"] or datetime.datetime.now()).date()
    y = _header(pdf, "Comprovante de entrega" if s["delivered_at"] else "Romaneio", s["number"], when, s["customer_id"],
                f"Pedido {s['order_number']}")
    lines = ana.sql("SELECT p.code, p.description, l.quantity FROM logistics.shipment_line l JOIN base.product p ON p.id = l.product_id "
                    "WHERE l.shipment_id = $1 ORDER BY l.order_line", s["id"])
    y = pdf.table(50, y, ["Item", "Quantidade"], [[f"{l['code']} — {l['description']}", compact(l["quantity"])] for l in lines],
                  widths=[400, 110])
    y -= 20
    for label, value in (("Transportadora", s["carrier"]), ("Rastreio", s["tracking"]),
                         ("Volumes", s["packages"]), ("Peso (kg)", compact(s["weight_kg"]) if s["weight_kg"] else None),
                         ("Despachado em", f"{s['shipped_at']:%d/%m/%Y %H:%M}" if s["shipped_at"] else None),
                         ("Entregue em", f"{s['delivered_at']:%d/%m/%Y %H:%M}" if s["delivered_at"] else None),
                         ("Recebido por", s["received_by"])):
        if value:
            pdf.text(50, y, f"{label}: {value}", size=9)
            y -= 13
    _footer(pdf)
    return s["customer_id"], f"Entrega {s['number']}.pdf", pdf.build()


def service_order(key):
    o = ana.sql_one("SELECT id, number, customer_id, description, site_address, equipment, serial_number, opened_at, done_at, status "
                    "FROM field.service_order WHERE number = $1", int(key))
    if not o:
        raise ana.Error("DOCUMENT_NOT_FOUND", f"OS {key} não encontrada")
    pdf = Pdf(title=f"Atendimento OS {o['number']}")
    y = _header(pdf, "Relatório de atendimento OS", o["number"], (o["done_at"] or o["opened_at"]).date(), o["customer_id"],
                o["description"][:100])
    for label, value in (("Local", o["site_address"]), ("Equipamento", o["equipment"]), ("Nº de série", o["serial_number"]),
                         ("Aberta em", f"{o['opened_at']:%d/%m/%Y %H:%M}"),
                         ("Concluída em", f"{o['done_at']:%d/%m/%Y %H:%M}" if o["done_at"] else "em andamento")):
        if value:
            pdf.text(50, y, f"{label}: {value}", size=9)
            y -= 13
    visits = ana.sql("SELECT e.name, lower(a.period) AS b, upper(a.period) AS e FROM field.assignment a "
                     "JOIN projects.employee e ON e.id = a.employee_id WHERE a.order_id = $1 AND a.status <> 'cancelled' "
                     "ORDER BY lower(a.period)", o["id"])
    if visits:
        y = pdf.table(50, y - 8, ["Técnico", "Início", "Fim"],
                      [[v["name"], f"{v['b']:%d/%m/%Y %H:%M}", f"{v['e']:%H:%M}"] for v in visits], widths=[250, 130, 130])
    lines = ana.sql("SELECT l.description, l.quantity, l.unit_price, l.amount FROM field.invoice_line l "
                    "WHERE l.order_id = $1 ORDER BY l.line", o["id"])
    if lines:
        y = pdf.table(50, y - 12, ["Serviço / peça", "Qtd", "Unitário", "Valor"],
                      [[l["description"], compact(l["quantity"]), money(l["unit_price"]), money(l["amount"])] for l in lines],
                      widths=[300, 50, 80, 80])
    answers = ana.sql("SELECT COALESCE(t.question, 'item ' || a.item) AS question, a.answer FROM field.checklist_answer a "
                      "JOIN field.service_order so ON so.id = a.order_id LEFT JOIN field.checklist_template t "
                      "ON t.service_product_id = so.service_product_id AND t.item = a.item WHERE a.order_id = $1 ORDER BY a.item", o["id"])
    if answers:
        y = pdf.table(50, y - 12, ["Verificação", "Resposta"], [[a["question"], a["answer"]] for a in answers], widths=[360, 150])
    sign = ana.sql_one("SELECT signed_by, signed_at FROM field.sign_off WHERE order_id = $1", o["id"])
    if sign:
        pdf.text(50, y - 24, f"Aceite do cliente: {sign['signed_by']} em {sign['signed_at']:%d/%m/%Y %H:%M}", size=9, bold=True)
    _footer(pdf)
    return o["customer_id"], f"Atendimento OS-{o['number']}.pdf", pdf.build()


def receipt(key):
    b = ana.sql_one("SELECT b.id, b.party_id, b.document, b.amount, b.status, b.installment, b.installments, "
                    "  (SELECT max(c.paid_at) FROM finance.charge c WHERE c.bill_id = b.id) AS paid_at "
                    "FROM finance.bill b WHERE b.id = $1 AND b.kind = 'receivable'", int(key))
    if not b:
        raise ana.Error("DOCUMENT_NOT_FOUND", f"título {key} não encontrado")
    if b["status"] != "settled":
        raise ana.Error("NOT_PAID", "o recibo só existe para título pago")
    pdf = Pdf(title=f"Recibo {b['document']}")
    paid = (b["paid_at"] or datetime.datetime.now()).date()
    y = _header(pdf, "Recibo", b["document"], paid, b["party_id"])
    parcel = f", parcela {b['installment']} de {b['installments']}" if b["installments"] else ""
    pdf.text(50, y, f"Recebemos a importância de {money(b['amount'])} referente à fatura {b['document'].split('/')[0]}{parcel}.", size=10)
    pdf.text(50, y - 16, f"Pagamento registrado em {paid:%d/%m/%Y}.", size=10)
    _footer(pdf)
    return b["party_id"], f"Recibo {b['document'].replace('/', '-')}.pdf", pdf.build()


def statement(key, start=None, end=None):
    party = int(key)
    end = end or datetime.date.today()
    start = start or end.replace(day=1)
    bills = ana.sql("SELECT document, issue_date, due_date, amount, status FROM finance.bill WHERE party_id = $1 AND kind = 'receivable' "
                    "AND (status = 'open' OR issue_date BETWEEN $2 AND $3) ORDER BY due_date, document", party, start, end)
    pdf = Pdf(title="Extrato")
    y = _header(pdf, "Extrato", f"{start:%d/%m/%Y} a {end:%d/%m/%Y}", end, party, "Títulos emitidos no período e todos os em aberto")
    y = pdf.table(50, y, ["Documento", "Emissão", "Vencimento", "Valor", "Situação"],
                  [[x["document"], f"{x['issue_date']:%d/%m/%Y}", f"{x['due_date']:%d/%m/%Y}", money(x["amount"]),
                    STATUS.get(x["status"], x["status"])] for x in bills], widths=[120, 90, 90, 110, 100])
    open_total = sum(x["amount"] for x in bills if x["status"] == "open")
    pdf.text(330, y - 20, "Em aberto", bold=True)
    pdf.text(450, y - 20, money(open_total), bold=True)
    _footer(pdf)
    return party, f"Extrato {start:%Y-%m-%d} a {end:%Y-%m-%d}.pdf", pdf.build()


def purchase_order(key):
    o = ana.sql_one("SELECT o.id, o.number, o.supplier_id, o.created_at, o.total, o.payment_days, o.notes, w.code AS warehouse, "
                    "  w.description AS warehouse_name FROM supply.purchase_order o JOIN inventory.warehouse w ON w.id = o.warehouse_id "
                    "WHERE o.number = $1", int(key))
    if not o:
        raise ana.Error("DOCUMENT_NOT_FOUND", f"ordem de compra {key} não encontrada")
    pdf = Pdf(title=f"Ordem de compra {o['number']}")
    y = _header(pdf, "Ordem de compra", o["number"], o["created_at"].date(), o["supplier_id"],
                f"Entrega em: {o['warehouse']} — {o['warehouse_name']} · pagamento em {o['payment_days']} dias")
    lines = ana.sql("SELECT p.code, p.description, l.quantity, l.price, l.promised_date FROM supply.purchase_order_line l "
                    "JOIN base.product p ON p.id = l.product_id WHERE l.order_id = $1 ORDER BY l.line", o["id"])
    y = pdf.table(50, y, ["Item", "Qtd", "Preço", "Prazo"],
                  [[f"{l['code']} — {l['description']}", compact(l["quantity"]), money(l["price"]),
                    f"{l['promised_date']:%d/%m/%Y}" if l["promised_date"] else "—"] for l in lines], widths=[290, 60, 80, 80])
    pdf.line(50, y - 6, 560, y - 6)
    pdf.text(380, y - 22, "Total", bold=True)
    pdf.text(480, y - 22, money(o["total"]), bold=True)
    if o["notes"]:
        pdf.text(50, y - 46, f"Observações: {o['notes']}"[:110], size=9)
    _footer(pdf)
    return o["supplier_id"], f"Ordem de compra {o['number']}.pdf", pdf.build()


def bill(key):
    b = ana.sql_one("SELECT document FROM finance.bill WHERE id = $1 AND kind = 'receivable'", int(key))
    if not b:
        raise ana.Error("DOCUMENT_NOT_FOUND", f"título {key} não encontrado")
    party, data = invoice_pdf.build(b["document"])
    return party, invoice_pdf.file_name(b["document"]), data


EXTERNAL = {"order": order, "bill": bill, "shipment": shipment, "service_order": service_order, "receipt": receipt,
            "statement": statement, "purchase_order": purchase_order}
LABEL = {"order": "Pedido", "bill": "Fatura", "shipment": "Entrega", "service_order": "Atendimento", "receipt": "Recibo",
         "statement": "Extrato", "purchase_order": "Ordem de compra"}
SUBFOLDER = {"order": "Pedidos", "bill": "Faturas", "shipment": "Entregas", "service_order": "Atendimentos", "receipt": "Recibos",
             "statement": "Extratos", "purchase_order": "Ordens de compra"}


def build(kind, key, **opts):
    if kind not in EXTERNAL:
        raise ana.Error("INTERNAL_DOCUMENT", "documento interno: não pode ser entregue a clientes ou fornecedores")
    return EXTERNAL[kind](key, **opts) if kind == "statement" else EXTERNAL[kind](key)


def publish(kind, key, **opts):
    """File id of the published PDF (a new version when it already exists)."""
    party, name, data = build(kind, key, **opts)
    return ana.files.publish(kind, party, name, data, comment=f"{LABEL[kind]} {key}")["file"]


def publish_quietly(kind, key, **opts):
    """For automatic generation inside another routine: a repository problem never undoes it."""
    try:
        with ana.savepoint():           # a failure here rolls back only the PDF, never the document
            return publish(kind, key, **opts)
    except ana.Error as e:
        ana.log(f"{LABEL.get(kind, kind)} {key}: PDF não publicado ({e.message})", "warning")
        return None


def find(kind, party, name):
    try:
        folder = ana.files.folder(entity=("party", int(party)), subfolder=SUBFOLDER[kind], create=False)
        return next((f["id"] for f in ana.files.list(folder)["files"] if f["name"] == name), None)
    except ana.Error:
        return None
