# ana:description Abre um documento: cabeçalho, itens, valores, situação e documentos ligados
# ana:command doc
# ana:portal yes
# ana:category Documentos e arquivos/Documentos
"""Spec 035 (RF-035-02..04). One viewer for every document; each related document opens from
its row. Portal accounts see only documents of their own company (others: not found)."""

from ana_lib.docs import common
from ana_lib.util.format import compact, money

PARAMS = {
    "kind": {"type": "str", "required": True, "default": "order", "label": "documento", "order": 1,
             "choices": [["order", "Pedido de venda"], ["bill", "Título (fatura/parcela)"], ["service_order", "Ordem de serviço"],
                         ["purchase_request", "Solicitação de compra"], ["purchase_order", "Ordem de compra"],
                         ["work_order", "Ordem de produção"], ["shipment", "Expedição"], ["transfer", "Transferência"],
                         ["entry", "Lançamento contábil"], ["project_invoice", "Fatura de projeto"],
                         ["statement_line", "Linha do extrato"]]},
    "key": {"type": "str", "required": True, "label": "número", "order": 2},
}
STATUS = {"OPEN": "em aberto", "INVOICED": "faturado", "CANCELLED": "cancelado", "open": "em aberto", "settled": "pago",
          "cancelled": "cancelado", "requested": "pedida", "issued": "emitida", "paid": "paga", "failed": "falhou",
          "picking": "em separação", "packed": "embalada", "shipped": "despachada", "delivered": "entregue", "returned": "devolvida",
          "draft": "rascunho", "received": "recebida", "submitted": "enviada para aprovação", "approved": "aprovada",
          "rejected": "recusada", "ordered": "comprada", "sent": "enviada", "partial": "parcial", "closed": "encerrada",
          "planned": "planejada", "released": "liberada", "in_progress": "em andamento", "completed": "concluída",
          "scheduled": "agendada", "en_route": "a caminho", "done": "concluída", "invoiced": "faturada"}
PORTAL_KINDS = ("order", "bill", "service_order", "shipment")
FULFILLMENT = {"ok": "pode expedir", "held": "retido: aguardando estoque", "supply": "aguardando compra ou produção",
               "short": "aceito com falta"}


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


def pdf_actions(kind, key):
    """Spec 037: documents for partners have a PDF; staff can also send a download link."""
    acts = [{"label": "PDF", "program": "docs.pdf", "params": {"kind": kind, "key": str(key)}, "download": True}]
    if not ana.context.party:
        acts.append({"label": "Link para o cliente" if kind != "purchase_order" else "Link para o fornecedor",
                     "program": "docs.share_link", "params": {"kind": kind, "key": str(key), "_form": "1"}, "open": True})
    return acts


def flow_actions(flow, key):
    if ana.context.party:
        return []
    # RF-020-11: where the document is in its process, always; the esteira when it follows the document.
    out = [{"label": "Etapas do processo", "program": "flows.guide", "params": {"flow": flow, "document": str(key)}, "open": True}]
    if ana.sql_value("SELECT count(*) FROM flow.instance WHERE flow_code = $1 AND doc_key = $2", flow, str(key)):
        out.append({"label": "Ver na esteira", "program": "flows.board", "params": {"flow": flow, "document": str(key)}, "open": True})
    return out


# ---------------------------------------------------------------- documents

def view_order(key):
    n = number("order", key)
    o = ana.sql_one("SELECT o.id, o.number, o.customer_id, p.name AS customer, o.order_date, o.status, o.total, o.notes, o.payment_term, "
                    "  w.code AS warehouse, o.created_by, o.invoiced_at, o.fulfillment FROM sales.sales_order o JOIN base.party p ON p.id = o.customer_id "
                    "JOIN inventory.warehouse w ON w.id = o.warehouse_id WHERE o.number = $1", n)
    if not o:
        not_found("order", key)
    guard("order", key, o["customer_id"])
    ana.metrics([{"label": "Situação", "value": st(o["status"]), "status": "ok" if o["status"] == "INVOICED" else None},
                 {"label": "Total", "value": money(o["total"])}, {"label": "Data", "value": f"{o['order_date']:%d/%m/%Y}"},
                 {"label": "Condição", "value": o["payment_term"] or "padrão"},
                 *([{"label": "Atendimento", "value": FULFILLMENT[o["fulfillment"]], "status": "warn"}]
                   if o["status"] == "OPEN" and o["fulfillment"] != "ok" else [])],
                title=f"Pedido de venda {o['number']} — {o['customer']} (depósito {o['warehouse']})")
    items = ana.sql("SELECT i.line, p.code, p.description, i.quantity, i.price, i.amount, i.supply_qty, i.supply_kind, i.promised_date "
                    "FROM sales.sales_order_item i JOIN base.product p ON p.id = i.product_id WHERE i.order_id = $1 ORDER BY i.line", o["id"])
    supplied = any(i["supply_qty"] for i in items)
    ana.table([{"linha": i["line"], "item": f"{i['code']} — {i['description']}", "quantidade": compact(i["quantity"]),
                "preço": money(i["price"]), "valor": money(i["amount"]),
                **({"vem de": (f"{compact(i['supply_qty'])} de {'compra' if i['supply_kind'] == 'purchase' else 'produção'}"
                               if i["supply_qty"] else "estoque"),
                    "prometido": i["promised_date"].strftime("%d/%m/%Y") if i["promised_date"] else "—"} if supplied else {})}
               for i in items], title="Itens")
    # Spec 041 (RF-041-07): the supply made for this order, each one opens.
    linked = ana.sql("SELECT 'purchase_request' AS kind, r.number, r.status, string_agg(DISTINCT p.code, ', ') AS items, "
                     "  bool_or(l.work_order_id IS NOT NULL) AS component FROM supply.purchase_request_line l "
                     "JOIN supply.purchase_request r ON r.id = l.request_id JOIN base.product p ON p.id = l.product_id "
                     "WHERE l.sales_order_id = $1 GROUP BY r.number, r.status "
                     "UNION ALL SELECT 'work_order', w.number, w.status, p.code, false FROM production.work_order w "
                     "JOIN base.product p ON p.id = w.product_id WHERE w.sales_order_id = $1 ORDER BY 1, 2", o["id"])
    if linked and not ana.context.party:          # internal documents: not for portal accounts
        ana.table([{"documento": ("Solicitação de compra" + (" (insumos da produção)" if x["component"] else "") if x["kind"] == "purchase_request"
                                  else "Ordem de produção") + f" {x['number']}", "itens": x["items"], "situação": st(x["status"]),
                    "_open": common.link(x["kind"], x["number"])} for x in linked], title="Suprimento vinculado")
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
    acts += flow_actions("sales", o["number"]) + pdf_actions("order", o["number"])
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
    if b["kind"] == "receivable":
        acts.insert(0, {"label": "PDF da fatura", "program": "finance.bill_pdf", "params": {"bill": b["id"]}, "download": True,
                        "style": "primary"})
    if b["kind"] == "receivable" and not ana.context.party:
        acts.append({"label": "Link para o cliente", "program": "docs.share_link",
                     "params": {"kind": "bill", "key": str(b["id"]), "_form": "1"}, "open": True})
    if b["kind"] == "receivable" and b["status"] == "settled":
        acts.append({"label": "Recibo", "program": "docs.pdf", "params": {"kind": "receipt", "key": str(b["id"])}, "download": True})
    if not ana.context.party:
        settled_by(b)
    acts += entry_link(b["entry_id"])
    acts.append({"label": "Todas as faturas do cliente", "program": "files.my_invoices", "params": {"customer": b["party_id"]}, "open": True})
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
    acts = pdf_actions("service_order", o["number"]) + flow_actions("field", o["number"]) + entry_link(o["entry_id"])
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
    back = ana.sql("SELECT DISTINCT so.number AS sales, w.number AS wo FROM supply.purchase_request_line l "
                   "LEFT JOIN sales.sales_order so ON so.id = l.sales_order_id LEFT JOIN production.work_order w ON w.id = l.work_order_id "
                   "WHERE l.request_id = $1 AND l.sales_order_id IS NOT NULL", r["id"])
    if back:
        ana.table([{"para": (f"Ordem de produção {b['wo']}, do pedido de venda {b['sales']}" if b["wo"] else f"Pedido de venda {b['sales']}"),
                    "_open": common.link("work_order", b["wo"]) if b["wo"] else common.link("order", b["sales"])} for b in back],
                  title="Comprado para")
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
    acts = pdf_actions("purchase_order", o["number"])
    if o["status"] not in ("received", "cancelled", "closed"):
        acts.insert(0, {"label": "Receber", "program": "supply.receive", "params": {"order": o["number"], "_form": "1"}, "open": True})
    ana.actions(acts, title="Próximo passo")
    return {"kind": "purchase_order", "number": o["number"], "status": o["status"]}


def view_work_order(key):
    o = ana.sql_one("SELECT o.id, o.number, p.code, p.description, o.quantity, o.status, o.due_date, o.good_qty, o.scrap_qty, "
                    "  o.std_cost, o.actual_cost, o.variance, so.number AS sales FROM production.work_order o JOIN base.product p ON p.id = o.product_id "
                    "LEFT JOIN sales.sales_order so ON so.id = o.sales_order_id "
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
    buys = ana.sql("SELECT DISTINCT r.number, r.status FROM supply.purchase_request_line l JOIN supply.purchase_request r ON r.id = l.request_id "
                   "WHERE l.work_order_id = $1 ORDER BY r.number", o["id"])
    if o["sales"] or buys:
        ana.table(([{"documento": f"Pedido de venda {o['sales']}", "papel": "a ordem atende este pedido", "situação": "",
                     "_open": common.link("order", o["sales"])}] if o["sales"] else [])
                  + [{"documento": f"Solicitação de compra {b['number']}", "papel": "insumos que faltavam", "situação": st(b["status"]),
                      "_open": common.link("purchase_request", b["number"])} for b in buys], title="Vínculos (spec 041)")
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
    guard("shipment", key, s["customer_id"])
    ana.metrics([{"label": "Situação", "value": st(s["status"])}, {"label": "Transportadora", "value": s["carrier"] or "—"},
                 {"label": "Rastreio", "value": s["tracking"] or "—"},
                 {"label": "Frete", "value": money(s["freight_cost"]) if s["freight_cost"] is not None else "—"}],
                title=f"Expedição {s['number']} do pedido {s['order_number']}")
    lines = ana.sql("SELECT l.order_line, p.code, p.description, l.quantity FROM logistics.shipment_line l "
                    "JOIN base.product p ON p.id = l.product_id WHERE l.shipment_id = $1 ORDER BY l.order_line", s["id"])
    ana.table([{"linha do pedido": l["order_line"], "item": f"{l['code']} — {l['description']}", "quantidade": compact(l["quantity"])}
               for l in lines], title="Itens")
    ana.actions([{"label": f"Abrir pedido {s['order_number']}", "program": "docs.view",
                  "params": {"kind": "order", "key": str(s["order_number"])}, "open": True}] + pdf_actions("shipment", s["number"]),
                title="Relacionados")
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
    pair = common.offset_bills(e["document"])
    acts = [{"label": f"Abrir {common.KINDS[origin[0]].lower()}", "program": "docs.view",
             "params": {"kind": origin[0], "key": origin[1]}, "open": True}] if origin else []
    if pair:                                   # a compensation: the credit used and the bill it paid
        acts += [{"label": f"Abrir o crédito ({pair[0]})", **common.link("bill", pair[0]), "open": True},
                 {"label": f"Abrir o título compensado ({pair[1]})", **common.link("bill", pair[1]), "open": True}]
    if acts:
        ana.actions(acts, title="Relacionados")
    return {"kind": "entry", "id": e["id"], "document": e["document"]}


def settled_by(b):
    """Spec 042 (M-02): how a bill was settled — statement lines, compensations, the residual left open."""
    rows = [{"como": "extrato", "quando": m["posted_on"], "histórico": m["description"], "valor": money(m["amount"]),
             "_open": common.link("statement_line", m["line_id"])}
            for m in ana.sql("SELECT x.line_id, l.posted_on, l.description, x.amount FROM finance.bank_match x "
                             "JOIN finance.bank_statement_line l ON l.id = x.line_id WHERE x.bill_id = $1 ORDER BY l.posted_on", b["id"])]
    rows += [{"como": "compensação", "quando": o["created_at"].date(), "histórico": f"com o título {o['other_doc']}", "valor": money(o["amount"]),
              "_open": common.link("bill", o["other"])}
             for o in ana.sql("SELECT CASE WHEN o.credit_bill = $1 THEN o.debit_bill ELSE o.credit_bill END AS other, o.amount, o.created_at, "
                              "  x.document AS other_doc FROM finance.offset o JOIN finance.bill x ON x.id = CASE WHEN o.credit_bill = $1 "
                              "  THEN o.debit_bill ELSE o.credit_bill END WHERE $1 IN (o.credit_bill, o.debit_bill) ORDER BY o.id", b["id"])]
    rows += [{"como": "cobrança", "quando": c["paid_at"], "histórico": c["method"], "valor": money(c["paid_amount"] or c["amount"]),
              "_open": common.link("entry", c["entry_id"])}
             for c in ana.sql("SELECT method, paid_at, paid_amount, amount, entry_id FROM finance.charge WHERE bill_id = $1 AND status = 'paid' "
                              "AND entry_id IS NOT NULL", b["id"])]
    rows += [{"como": "resíduo em aberto", "quando": r["issue_date"], "histórico": r["document"], "valor": money(r["amount"]),
              "_open": common.link("bill", r["id"])}
             for r in ana.sql("SELECT id, document, amount, issue_date FROM finance.bill WHERE parent_bill_id = $1", b["id"])]
    if rows:
        ana.table(rows, title="Como foi baixado")
    elif b["status"] == "settled":
        ana.table([{"como": "sem baixa registrada", "quando": None, "histórico": "baixado sem extrato, compensação nem cobrança",
                    "valor": money(b["amount"])}], title="Como foi baixado")


def view_project_invoice(key):
    i = ana.sql_one("SELECT i.id, i.number, i.issue_date, i.through_date, i.total, i.net_amount, i.status, i.bill_id, i.entry_id, "
                    "  p.code, p.name, c.name AS customer, i.customer_id FROM projects.invoice i JOIN projects.project p ON p.id = i.project_id "
                    "JOIN base.party c ON c.id = i.customer_id WHERE i.number = $1", number("project_invoice", key))
    if not i:
        not_found("project_invoice", key)
    guard("project_invoice", key, i["customer_id"])
    ana.metrics([{"label": "Situação", "value": st(i["status"])}, {"label": "Total", "value": money(i["total"])},
                 {"label": "Líquido", "value": money(i["net_amount"])}, {"label": "Até", "value": f"{i['through_date']:%d/%m/%Y}" if i["through_date"] else "—"}],
                title=f"Fatura de projeto {i['number']} — {i['code']} {i['name']} ({i['customer']})")
    ana.table([{"linha": l["line"], "origem": l["source"], "descrição": l["description"], "quantidade": compact(l["quantity"]),
                "preço": money(l["unit_price"]), "valor": money(l["amount"])}
               for l in ana.sql("SELECT line, source, description, quantity, unit_price, amount FROM projects.invoice_line "
                                "WHERE invoice_id = $1 ORDER BY line", i["id"])], title="Itens")
    acts = ([{"label": "Abrir o título", **common.link("bill", i["bill_id"]), "open": True}] if i["bill_id"] else []) + \
        ([{"label": "Abrir o projeto", "program": "projects.workspace", "params": {"project": i["code"]}, "open": True}] if not ana.context.party else []) + \
        (entry_link(i["entry_id"]) if not ana.context.party else [])
    ana.actions(acts, title="Relacionados")
    return {"kind": "project_invoice", "number": i["number"], "status": i["status"]}


def view_statement_line(key):
    l = ana.sql_one("SELECT l.id, l.bank_account, l.posted_on, l.amount, l.description, l.document, l.status, l.entry_id, l.rule "
                    "FROM finance.bank_statement_line l WHERE l.id = $1", number("statement_line", key))
    if not l or ana.context.party:
        not_found("statement_line", key)
    ana.metrics([{"label": "Situação", "value": {"open": "em aberto", "matched": "conciliada"}.get(l["status"], l["status"])},
                 {"label": "Valor", "value": money(l["amount"])}, {"label": "Data", "value": f"{l['posted_on']:%d/%m/%Y}"},
                 {"label": "Conta", "value": l["bank_account"]}], title=f"Linha do extrato {l['id']}: {l['description']}")
    bills = ana.sql("SELECT b.id, b.document, x.amount FROM finance.bank_match x JOIN finance.bill b ON b.id = x.bill_id WHERE x.line_id = $1", l["id"])
    if bills:
        ana.table([{"título": b["document"], "valor": money(b["amount"]), "_open": common.link("bill", b["id"])} for b in bills], title="Títulos baixados")
    ana.actions(entry_link(l["entry_id"]) + [{"label": "Conciliação da conta", "program": "finance.reconciliation",
                                               "params": {"bank_account": l["bank_account"]}, "open": True}], title="Relacionados")
    return {"kind": "statement_line", "id": l["id"], "status": l["status"]}


VIEWS = {"order": view_order, "bill": view_bill, "service_order": view_service_order, "purchase_request": view_purchase_request,
         "purchase_order": view_purchase_order, "work_order": view_work_order, "shipment": view_shipment, "transfer": view_transfer,
         "entry": view_entry, "project_invoice": view_project_invoice, "statement_line": view_statement_line}


def main(kind, key):
    if kind not in VIEWS:
        raise ana.Error("INVALID_PARAMETER", f"tipo de documento desconhecido: {kind}")
    if ana.context.party and kind not in PORTAL_KINDS:
        not_found(kind, key)
    return VIEWS[kind](key)
