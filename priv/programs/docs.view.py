# ana:description Abre um documento: cabeçalho, itens, valores, situação e documentos ligados
# ana:command doc
# ana:portal yes
"""Spec 035 (RF-035-02..04). One viewer for every document; each related document opens from
its row. Portal accounts see only documents of their own company (others: not found)."""

from ana_lib.docs import common
from ana_lib.util.format import compact, money

PARAMS = {
    "kind": {"type": "str", "required": True, "default": "order", "label": "documento", "order": 1,
             "choices": [["order", "Pedido de venda"], ["bill", "Título (fatura/parcela)"], ["service_order", "Ordem de serviço"],
                         ["purchase_request", "Solicitação de compra"], ["purchase_order", "Ordem de compra"],
                         ["work_order", "Ordem de produção"], ["shipment", "Expedição"], ["transfer", "Transferência"],
                         ["entry", "Lançamento contábil"]]},
    "key": {"type": "str", "required": True, "label": "número", "order": 2},
}
STATUS = {"OPEN": "em aberto", "INVOICED": "faturado", "CANCELLED": "cancelado", "open": "em aberto", "settled": "pago",
          "cancelled": "cancelado", "requested": "pedida", "issued": "emitida", "paid": "paga", "failed": "falhou",
          "picking": "em separação", "packed": "embalada", "shipped": "despachada", "delivered": "entregue", "returned": "devolvida",
          "draft": "rascunho", "received": "recebida", "submitted": "enviada para aprovação", "approved": "aprovada",
          "rejected": "recusada", "ordered": "comprada", "sent": "enviada", "partial": "parcial", "closed": "encerrada",
          "planned": "planejada", "released": "liberada", "in_progress": "em andamento", "completed": "concluída",
          "scheduled": "agendada", "en_route": "a caminho", "done": "concluída", "invoiced": "faturada"}
PORTAL_KINDS = ("order", "bill", "service_order")


def st(s):
    return STATUS.get(s, s)


def not_found(kind, key):
    raise ana.Error("DOCUMENT_NOT_FOUND", f"{common.KINDS.get(kind, 'documento')} {key} não encontrado")


def guard(kind, key, party_id):
    """RF-035-04: a portal account opens only its own company's documents."""
    if ana.context.party and int(party_id or 0) != int(ana.context.party):
        not_found(kind, key)


def number(kind, key):
    try:
        return int(str(key).strip().upper().split("-")[-1].split("/")[0])
    except ValueError:
        not_found(kind, key)


def bills_table(document_like, title="Títulos"):
    rows = ana.sql("SELECT b.id, b.document, b.kind, b.due_date, b.amount, b.status, b.installment, b.installments, b.payment_method, "
                   "  (SELECT c.status FROM finance.charge c WHERE c.bill_id = b.id ORDER BY c.id DESC LIMIT 1) AS charge "
                   "FROM finance.bill b WHERE b.document = $1 OR b.document LIKE $1 || '/%' ORDER BY b.installment NULLS FIRST, b.id",
                   document_like)
    if rows:
        ana.table([{"título": r["document"], "parcela": f"{r['installment']}/{r['installments']}" if r["installments"] else "única",
                    "vencimento": r["due_date"], "valor": money(r["amount"]), "situação": st(r["status"]),
                    "cobrança": st(r["charge"]) if r["charge"] else "—", "_open": common.link("bill", r["id"])} for r in rows],
                  title=title)
    return rows


def entry_link(entry_id):
    return [{"label": "Lançamento contábil", "program": "docs.view", "params": {"kind": "entry", "key": str(entry_id)}, "open": True}] \
        if entry_id and not ana.context.party else []


def flow_actions(flow, key):
    if ana.context.party or not ana.sql_value("SELECT count(*) FROM flow.instance WHERE flow_code = $1 AND doc_key = $2", flow, str(key)):
        return []
    return [{"label": "Ver na esteira", "program": "flows.board", "params": {"flow": flow, "document": str(key)}, "open": True}]


# ---------------------------------------------------------------- documents

def view_order(key):
    n = number("order", key)
    o = ana.sql_one("SELECT o.id, o.number, o.customer_id, p.name AS customer, o.order_date, o.status, o.total, o.notes, o.payment_term, "
                    "  w.code AS warehouse, o.created_by, o.invoiced_at FROM sales.sales_order o JOIN base.party p ON p.id = o.customer_id "
                    "JOIN inventory.warehouse w ON w.id = o.warehouse_id WHERE o.number = $1", n)
    if not o:
        not_found("order", key)
    guard("order", key, o["customer_id"])
    ana.metrics([{"label": "Situação", "value": st(o["status"]), "status": "ok" if o["status"] == "INVOICED" else None},
                 {"label": "Total", "value": money(o["total"])}, {"label": "Data", "value": f"{o['order_date']:%d/%m/%Y}"},
                 {"label": "Condição", "value": o["payment_term"] or "padrão"}],
                title=f"Pedido de venda {o['number']} — {o['customer']} (depósito {o['warehouse']})")
    items = ana.sql("SELECT i.line, p.code, p.description, i.quantity, i.price, i.amount FROM sales.sales_order_item i "
                    "JOIN base.product p ON p.id = i.product_id WHERE i.order_id = $1 ORDER BY i.line", o["id"])
    ana.table([{"linha": i["line"], "item": f"{i['code']} — {i['description']}", "quantidade": compact(i["quantity"]),
                "preço": money(i["price"]), "valor": money(i["amount"])} for i in items], title="Itens")
    ships = ana.sql("SELECT number, status, tracking, shipped_at, delivered_at FROM logistics.shipment WHERE sales_order_id = $1 ORDER BY number",
                    o["id"])
    if ships:
        ana.table([{"expedição": s["number"], "situação": st(s["status"]), "rastreio": s["tracking"] or "—",
                    "despachada": s["shipped_at"], "entregue": s["delivered_at"], "_open": common.link("shipment", s["number"])}
                   for s in ships], title="Expedições")
    bills = bills_table(f"ORD-{o['number']}", "Faturas e parcelas")
    acts = []
    if o["status"] == "OPEN" and not ana.context.party:
        acts += [{"label": "Faturar", "program": "sales.invoice_order", "params": {"number": o["number"]}, "style": "primary",
                  "confirm": f"Faturar o pedido {o['number']}?"},
                 {"label": "Expedir", "program": "logistics.ship", "params": {"order": o["number"], "_form": "1"}, "open": True}]
    acts += flow_actions("sales", o["number"])
    if acts:
        ana.actions(acts, title="Próximo passo")
    return {"kind": "order", "number": o["number"], "status": o["status"], "total": o["total"], "shipments": len(ships), "bills": len(bills)}


def view_bill(key):
    b = ana.sql_one("SELECT b.id, b.kind, b.party_id, p.name AS party, b.document, b.issue_date, b.due_date, b.amount, b.status, "
                    "  b.installment, b.installments, b.payment_method, b.payment_term, b.entry_id "
                    "FROM finance.bill b JOIN base.party p ON p.id = b.party_id WHERE b.id = $1", number("bill", key))
    if not b:
        not_found("bill", key)
    guard("bill", key, b["party_id"])
    late = b["status"] == "open" and b["due_date"] < ana.sql_value("SELECT current_date")
    ana.metrics([{"label": "Valor", "value": money(b["amount"])},
                 {"label": "Vencimento", "value": f"{b['due_date']:%d/%m/%Y}", "status": "bad" if late else None},
                 {"label": "Situação", "value": "vencido" if late else st(b["status"]), "status": "ok" if b["status"] == "settled" else None},
                 {"label": "Parcela", "value": f"{b['installment']} de {b['installments']}" if b["installments"] else "única"}],
                title=f"{'Título a receber' if b['kind'] == 'receivable' else 'Título a pagar'} {b['document']} — {b['party']}")
    charges = ana.sql("SELECT id, method, status, amount, paid_amount, paid_at, digitable_line, url, created_at FROM finance.charge "
                      "WHERE bill_id = $1 ORDER BY id", b["id"])
    if charges:
        ana.table([{"cobrança": c["id"], "forma": {"pix": "PIX", "boleto": "Boleto", "card_link": "Cartão"}.get(c["method"], c["method"]),
                    "situação": st(c["status"]), "valor": money(c["amount"]), "pago": money(c["paid_amount"]) if c["paid_amount"] else "—",
                    "linha digitável / link": c["digitable_line"] or c["url"] or "—"} for c in charges], title="Cobranças")
    origin = common.of_text(b["document"])
    acts = []
    if origin:
        acts.append({"label": f"Abrir {common.KINDS[origin[0]].lower()} de origem", "program": "docs.view",
                     "params": {"kind": origin[0], "key": origin[1]}, "open": True})
    others = ana.sql("SELECT id, document FROM finance.bill WHERE id <> $1 AND document LIKE split_part($2, '/', 1) || '/%' ORDER BY installment",
                     b["id"], b["document"]) if b["installments"] else []
    if others:
        ana.table([{"outras parcelas": o["document"], "_open": common.link("bill", o["id"])} for o in others], title="Outras parcelas")
    gateway = ana.sql_value("SELECT connector FROM finance.payment_term WHERE code = $1", b["payment_term"]) if b["payment_term"] else None
    if not ana.context.party and b["status"] == "open" and b["kind"] == "receivable" and not charges and gateway:
        acts.append({"label": "Emitir cobrança", "program": "finance.charge_document", "params": {"document": b["document"]},
                     "confirm": "Emitir a cobrança deste título pelo gateway da condição de pagamento?"})
    acts += entry_link(b["entry_id"])
    acts.append({"label": "Faturas e PDFs do cliente", "program": "files.my_invoices", "params": {"customer": b["party_id"]}, "open": True})
    ana.actions(acts, title="Relacionados")
    return {"kind": "bill", "id": b["id"], "document": b["document"], "amount": b["amount"], "status": b["status"],
            "due_date": b["due_date"], "charges": len(charges), "origin": origin and {"kind": origin[0], "key": origin[1]}}


def view_service_order(key):
    o = ana.sql_one("SELECT o.id, o.number, o.customer_id, p.name AS customer, o.status, o.priority, o.description, o.site_address, "
                    "  o.equipment, o.serial_number, o.opened_at, o.due_at, o.done_at, o.entry_id FROM field.service_order o "
                    "JOIN base.party p ON p.id = o.customer_id WHERE o.number = $1", number("service_order", key))
    if not o:
        not_found("service_order", key)
    guard("service_order", key, o["customer_id"])
    ana.metrics([{"label": "Situação", "value": st(o["status"])}, {"label": "Prioridade", "value": o["priority"]},
                 {"label": "Aberta", "value": f"{o['opened_at']:%d/%m/%Y %H:%M}"},
                 {"label": "Prazo (SLA)", "value": f"{o['due_at']:%d/%m/%Y %H:%M}" if o["due_at"] else "—"}],
                title=f"Ordem de serviço {o['number']} — {o['customer']}: {o['description']}")
    visits = ana.sql("SELECT e.name, lower(a.period) AS b, a.status, a.distance_km, a.travel_min FROM field.assignment a "
                     "JOIN projects.employee e ON e.id = a.employee_id WHERE a.order_id = $1 ORDER BY lower(a.period)", o["id"])
    if visits:
        ana.table([{"técnico": v["name"], "início": v["b"], "situação": st(v["status"]),
                    "distância (km)": v["distance_km"], "deslocamento (min)": v["travel_min"]} for v in visits], title="Visitas")
    lines = ana.sql("SELECT line, kind, description, quantity, unit_price, amount FROM field.invoice_line WHERE order_id = $1 ORDER BY line",
                    o["id"])
    if lines:
        ana.table([{"linha": l["line"], "descrição": l["description"], "quantidade": compact(l["quantity"]),
                    "unitário": money(l["unit_price"]), "valor": money(l["amount"])} for l in lines], title="Faturado")
    bills_table(f"OS-{o['number']}", "Faturas")
    acts = flow_actions("field", o["number"]) + entry_link(o["entry_id"])
    if acts:
        ana.actions(acts, title="Relacionados")
    return {"kind": "service_order", "number": o["number"], "status": o["status"]}


def view_purchase_request(key):
    r = ana.sql_one("SELECT r.id, r.number, r.requester, r.status, r.reason, r.total, r.need_date, w.code AS warehouse, r.approved_by "
                    "FROM supply.purchase_request r JOIN inventory.warehouse w ON w.id = r.warehouse_id WHERE r.number = $1",
                    number("purchase_request", key))
    if not r:
        not_found("purchase_request", key)
    ana.metrics([{"label": "Situação", "value": st(r["status"])}, {"label": "Total estimado", "value": money(r["total"])},
                 {"label": "Solicitante", "value": r["requester"]}, {"label": "Aprovada por", "value": r["approved_by"] or "—"}],
                title=f"Solicitação de compra {r['number']}: {r['reason']}")
    lines = ana.sql("SELECT l.line, p.code, p.description, l.quantity, l.est_price FROM supply.purchase_request_line l "
                    "JOIN base.product p ON p.id = l.product_id WHERE l.request_id = $1 ORDER BY l.line", r["id"])
    ana.table([{"linha": l["line"], "item": f"{l['code']} — {l['description']}", "quantidade": compact(l["quantity"]),
                "preço estimado": money(l["est_price"]) if l["est_price"] is not None else "—"} for l in lines], title="Itens")
    orders = ana.sql("SELECT DISTINCT po.number, po.status FROM supply.purchase_order_line l JOIN supply.purchase_order po ON po.id = l.order_id "
                     "WHERE l.request_id = $1 ORDER BY po.number", r["id"])
    if orders:
        ana.table([{"ordem de compra": o["number"], "situação": st(o["status"]), "_open": common.link("purchase_order", o["number"])}
                   for o in orders], title="Ordens de compra")
    acts = flow_actions("purchase", r["number"])
    if r["status"] == "submitted":
        acts.insert(0, {"label": "Aprovar ou recusar", "program": "supply.approve_request", "params": {"request": r["number"], "_form": "1"},
                        "open": True})
    if acts:
        ana.actions(acts, title="Próximo passo")
    return {"kind": "purchase_request", "number": r["number"], "status": r["status"]}


def view_purchase_order(key):
    o = ana.sql_one("SELECT o.id, o.number, p.name AS supplier, o.status, o.total, o.payment_days, w.code AS warehouse, o.sent_at "
                    "FROM supply.purchase_order o JOIN base.party p ON p.id = o.supplier_id JOIN inventory.warehouse w ON w.id = o.warehouse_id "
                    "WHERE o.number = $1", number("purchase_order", key))
    if not o:
        not_found("purchase_order", key)
    ana.metrics([{"label": "Situação", "value": st(o["status"])}, {"label": "Total", "value": money(o["total"])},
                 {"label": "Prazo de pagamento", "value": f"{o['payment_days']} dias"}, {"label": "Depósito", "value": o["warehouse"]}],
                title=f"Ordem de compra {o['number']} — {o['supplier']}")
    lines = ana.sql("SELECT l.line, p.code, p.description, l.quantity, l.received_qty, l.price, l.promised_date, r.number AS request "
                    "FROM supply.purchase_order_line l JOIN base.product p ON p.id = l.product_id "
                    "LEFT JOIN supply.purchase_request r ON r.id = l.request_id WHERE l.order_id = $1 ORDER BY l.line", o["id"])
    ana.table([{"linha": l["line"], "item": f"{l['code']} — {l['description']}", "pedida": compact(l["quantity"]),
                "recebida": compact(l["received_qty"]), "preço": money(l["price"]), "prometida": l["promised_date"],
                "solicitação": l["request"] or "—", "_open": common.link("purchase_request", l["request"]) if l["request"] else None}
               for l in lines], title="Linhas")
    receipts = ana.sql("SELECT r.id, r.document, r.received_at, r.total, b.id AS bill, b.status FROM supply.receipt r "
                       "LEFT JOIN finance.bill b ON b.id = r.bill_id WHERE r.order_id = $1 ORDER BY r.id", o["id"])
    if receipts:
        ana.table([{"recebimento": r["id"], "nota": r["document"] or "—", "em": r["received_at"], "valor": money(r["total"]),
                    "título a pagar": st(r["status"]) if r["bill"] else "—",
                    "_open": common.link("bill", r["bill"]) if r["bill"] else None} for r in receipts], title="Recebimentos")
    if o["status"] not in ("received", "cancelled", "closed"):
        ana.actions([{"label": "Receber", "program": "supply.receive", "params": {"order": o["number"], "_form": "1"}, "open": True}],
                    title="Próximo passo")
    return {"kind": "purchase_order", "number": o["number"], "status": o["status"]}


def view_work_order(key):
    o = ana.sql_one("SELECT o.id, o.number, p.code, p.description, o.quantity, o.status, o.due_date, o.good_qty, o.scrap_qty, "
                    "  o.std_cost, o.actual_cost, o.variance FROM production.work_order o JOIN base.product p ON p.id = o.product_id "
                    "WHERE o.number = $1", number("work_order", key))
    if not o:
        not_found("work_order", key)
    ana.metrics([{"label": "Situação", "value": st(o["status"])}, {"label": "Quantidade", "value": compact(o["quantity"])},
                 {"label": "Boas / refugo", "value": f"{compact(o['good_qty'] or 0)} / {compact(o['scrap_qty'] or 0)}"},
                 {"label": "Prazo", "value": f"{o['due_date']:%d/%m/%Y}" if o["due_date"] else "—"}],
                title=f"Ordem de produção {o['number']} — {o['code']} {o['description']}")
    comps = ana.sql("SELECT c.line, p.code, p.description, c.qty_required, c.reserved_qty, c.issued_qty FROM production.order_component c "
                    "JOIN base.product p ON p.id = c.product_id WHERE c.order_id = $1 ORDER BY c.line", o["id"])
    ana.table([{"linha": c["line"], "componente": f"{c['code']} — {c['description']}", "necessário": compact(c["qty_required"]),
                "reservado": compact(c["reserved_qty"]), "requisitado": compact(c["issued_qty"])} for c in comps], title="Componentes")
    ops = ana.sql("SELECT seq, resource_code, description, std_hours, actual_hours, good_qty FROM production.order_operation "
                  "WHERE order_id = $1 ORDER BY seq", o["id"])
    if ops:
        ana.table([{"operação": f"{x['seq']} — {x['description']}", "recurso": x["resource_code"], "horas padrão": x["std_hours"],
                    "horas reais": x["actual_hours"], "boas": x["good_qty"]} for x in ops], title="Operações")
    acts = flow_actions("production", o["number"])
    if acts:
        ana.actions(acts, title="Relacionados")
    return {"kind": "work_order", "number": o["number"], "status": o["status"]}


def view_shipment(key):
    s = ana.sql_one("SELECT s.id, s.number, s.status, s.tracking, s.packages, s.weight_kg, s.freight_cost, s.freight_charged, "
                    "  s.shipped_at, s.delivered_at, o.number AS order_number, o.customer_id, c.name AS carrier "
                    "FROM logistics.shipment s JOIN sales.sales_order o ON o.id = s.sales_order_id "
                    "LEFT JOIN logistics.carrier c ON c.id = s.carrier_id WHERE s.number = $1", number("shipment", key))
    if not s:
        not_found("shipment", key)
    ana.metrics([{"label": "Situação", "value": st(s["status"])}, {"label": "Transportadora", "value": s["carrier"] or "—"},
                 {"label": "Rastreio", "value": s["tracking"] or "—"},
                 {"label": "Frete", "value": money(s["freight_cost"]) if s["freight_cost"] is not None else "—"}],
                title=f"Expedição {s['number']} do pedido {s['order_number']}")
    lines = ana.sql("SELECT l.order_line, p.code, p.description, l.quantity FROM logistics.shipment_line l "
                    "JOIN base.product p ON p.id = l.product_id WHERE l.shipment_id = $1 ORDER BY l.order_line", s["id"])
    ana.table([{"linha do pedido": l["order_line"], "item": f"{l['code']} — {l['description']}", "quantidade": compact(l["quantity"])}
               for l in lines], title="Itens")
    ana.actions([{"label": f"Abrir pedido {s['order_number']}", "program": "docs.view",
                  "params": {"kind": "order", "key": str(s["order_number"])}, "open": True}], title="Relacionados")
    return {"kind": "shipment", "number": s["number"], "status": s["status"], "order": s["order_number"]}


def view_transfer(key):
    t = ana.sql_one("SELECT t.id, t.number, t.status, f.code AS src, d.code AS dst, t.notes, t.shipped_at, t.received_at "
                    "FROM logistics.transfer t JOIN inventory.warehouse f ON f.id = t.from_wh JOIN inventory.warehouse d ON d.id = t.to_wh "
                    "WHERE t.number = $1", number("transfer", key))
    if not t:
        not_found("transfer", key)
    ana.metrics([{"label": "Situação", "value": st(t["status"])}, {"label": "De → para", "value": f"{t['src']} → {t['dst']}"}],
                title=f"Transferência {t['number']}" + (f": {t['notes']}" if t["notes"] else ""))
    lines = ana.sql("SELECT l.line, p.code, p.description, l.quantity, l.received_qty, l.divergence FROM logistics.transfer_line l "
                    "JOIN base.product p ON p.id = l.product_id WHERE l.transfer_id = $1 ORDER BY l.line", t["id"])
    ana.table([{"linha": l["line"], "item": f"{l['code']} — {l['description']}", "enviada": compact(l["quantity"]),
                "recebida": compact(l["received_qty"]) if l["received_qty"] is not None else "—", "divergência": l["divergence"] or ""}
               for l in lines], title="Itens")
    if t["status"] in ("draft", "shipped"):
        action = "dispatch" if t["status"] == "draft" else "receive"
        ana.actions([{"label": "Despachar" if action == "dispatch" else "Receber", "program": "logistics.transfer",
                      "params": {"action": action, "number": t["number"]}, "style": "primary"}], title="Próximo passo")
    return {"kind": "transfer", "number": t["number"], "status": t["status"]}


def view_entry(key):
    e = ana.sql_one("SELECT id, entry_date, memo, document, created_by FROM finance.journal_entry WHERE id = $1", number("entry", key))
    if not e or ana.context.party:
        not_found("entry", key)
    lines = ana.sql("SELECT l.account, a.description, l.debit, l.credit, l.cost_center FROM finance.journal_line l "
                    "JOIN finance.account a ON a.code = l.account WHERE l.entry_id = $1 ORDER BY l.id", e["id"])
    ana.metrics([{"label": "Data", "value": f"{e['entry_date']:%d/%m/%Y}"}, {"label": "Documento", "value": e["document"] or "—"},
                 {"label": "Total", "value": money(sum(l["debit"] for l in lines))}], title=f"Lançamento {e['id']}: {e['memo']}")
    ana.table([{"conta": f"{l['account']} — {l['description']}", "débito": money(l["debit"]) if l["debit"] else "",
                "crédito": money(l["credit"]) if l["credit"] else "", "centro de custo": l["cost_center"] or ""} for l in lines],
              title="Partidas")
    origin = common.of_text(e["document"])
    if origin:
        ana.actions([{"label": f"Abrir {common.KINDS[origin[0]].lower()}", "program": "docs.view",
                      "params": {"kind": origin[0], "key": origin[1]}, "open": True}], title="Relacionados")
    return {"kind": "entry", "id": e["id"], "document": e["document"]}


VIEWS = {"order": view_order, "bill": view_bill, "service_order": view_service_order, "purchase_request": view_purchase_request,
         "purchase_order": view_purchase_order, "work_order": view_work_order, "shipment": view_shipment, "transfer": view_transfer,
         "entry": view_entry}


def main(kind, key):
    if kind not in VIEWS:
        raise ana.Error("INVALID_PARAMETER", f"tipo de documento desconhecido: {kind}")
    if ana.context.party and kind not in PORTAL_KINDS:
        not_found(kind, key)
    return VIEWS[kind](key)
