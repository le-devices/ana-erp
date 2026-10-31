"""Business-process trail audit: runs each trail end to end through the real programs and records where it breaks.
Usage: python3 audit.py [trail ...]"""
import datetime
import json
import os
import sys
import time

sys.path.insert(0, "/home/andre/ana-erp/tests/integration")
import test_integration as T  # noqa: E402

TOKEN = T.admin_token()
SFX = str(int(time.time()))[-6:]
FINDINGS = []
LOG = []


def run(program, _token=None, **params):
    s, c, _ = T.http("POST", f"/api/programs/{program}/run", {"params": params}, _token or TOKEN)
    ok = s == 200 and "error" not in c
    LOG.append((program, params, ok, c.get("error") if not ok else None))
    return ok, (c.get("result") if ok else c.get("error")), c


def must(program, _token=None, **params):
    ok, r, _ = run(program, _token, **params)
    if not ok:
        raise Stop(f"{program} falhou: {r.get('code')}: {r.get('message')}")
    return r


def sql(q):
    s, c, _ = T.http("POST", "/api/sql", {"sql": q}, TOKEN)
    if s != 200:
        raise RuntimeError(c)
    return c["rows"]


def one(q):
    r = sql(q)
    return r[0][0] if r else None


class Stop(Exception):
    pass


def finding(trail, severity, text):
    FINDINGS.append((trail, severity, text))
    print(f"  [{severity}] {text}")


def recon():
    r = must("finance.reconciliations")
    return {k: float(v or 0) for k, v in r["items"].items()}


def delta(before, after):
    return {k: round(after.get(k, 0) - before.get(k, 0), 2) for k in after if abs(after.get(k, 0) - before.get(k, 0)) >= 0.01}


def ledger_balanced():
    return one("SELECT round(sum(debit) - sum(credit), 2) FROM finance.journal_line") in (0, "0", "0.00", None)


def entries_unbalanced():
    return sql("SELECT e.id, e.memo FROM finance.journal_entry e JOIN finance.journal_line l ON l.entry_id = e.id "
               "GROUP BY e.id, e.memo HAVING round(sum(l.debit) - sum(l.credit), 2) <> 0 LIMIT 5")


def statement_pay(bank, lines):
    day = datetime.date.today().strftime("%d/%m/%Y")
    csv = "data;histórico;valor\n" + "".join(f"{day};{desc};{str(amount).replace('.', ',')}\n" for desc, amount in lines)
    return must("finance.import_statement", bank_account=bank, format="csv", content=csv, reconcile=True)


TRAILS = {}


def trail(fn):
    TRAILS[fn.__name__] = fn
    return fn


# ------------------------------------------------------------------------------------------------ setup
def base():
    c = must("base.save_party", name=f"Cliente Vistoria {SFX}", state="SP")["id"]
    sup = must("base.save_party", name=f"Fornecedor Vistoria {SFX}", kind="supplier", state="SP")["id"]
    item = f"VIS{SFX}"
    must("base.save_product", code=item, description=f"Item vistoria {SFX}", price="50")
    must("inventory.stock_in", product=item, quantity=100, warehouse="CENTRAL", unit_cost="20")
    svc = f"VSV{SFX}"
    must("base.save_product", code=svc, description=f"Serviço vistoria {SFX}", price="80", kind="service")
    carrier = must("logistics.save_carrier", name=f"Transp Vistoria {SFX}")["id"]
    return {"customer": c, "supplier": sup, "item": item, "service": svc, "carrier": carrier}


# ------------------------------------------------------------------------------------------------ trails
@trail
def venda(b):
    r0 = recon()
    o = must("sales.create_order", customer=b["customer"], items=[{"product": b["item"], "quantity": 3}, {"product": b["service"], "quantity": 1}])
    n = o["number"]
    sh = must("logistics.ship", order=n, carrier=b["carrier"])
    if not sh.get("shipment"):
        finding("venda", "alto", f"expedição do pedido {n} não aconteceu: {sh}")
    else:
        must("logistics.deliver", shipment=sh["shipment"], received_by="Fulano")
    inv = must("sales.invoice_order", number=n)
    bills = sql(f"SELECT document, amount FROM finance.bill WHERE document = 'ORD-{n}' OR document LIKE 'ORD-{n}/%' ORDER BY id")
    if not bills:
        finding("venda", "alto", f"pedido {n} faturado sem título a receber")
    statement_pay("CAIXA", [(f"PIX {doc} CLIENTE", amount) for doc, amount in bills])
    left = one(f"SELECT count(*) FROM finance.bill WHERE (document = 'ORD-{n}' OR document LIKE 'ORD-{n}/%') AND status = 'open'")
    if int(left):
        finding("venda", "alto", f"pagamento no extrato não baixou os títulos do pedido {n} sozinho ({left} em aberto)")
    d = delta(r0, recon())
    if d:
        finding("venda", "alto", f"conciliações de controle mudaram após a venda: {d}")
    v = must("docs.view", kind="order", key=str(n))
    if v.get("shipments", 0) < 1 or v.get("bills", 0) < 1:
        finding("venda", "médio", f"documento do pedido não mostra expedição/títulos: {v}")
    return {"order": n, "invoice": inv}


@trail
def devolucao(b):
    """Invoice cancelled after shipping; customer return with credit."""
    r0 = recon()
    n = must("sales.create_order", customer=b["customer"], items=[{"product": b["item"], "quantity": 2}])["number"]
    stock0 = float(one(f"SELECT sum(quantity) FROM inventory.stock_movement m JOIN base.product p ON p.id = m.product_id WHERE p.code = '{b['item']}'"))
    sh = must("logistics.ship", order=n, carrier=b["carrier"])
    must("sales.invoice_order", number=n)
    ok, r, _ = run("sales.cancel_invoice", number=n, reason="vistoria")
    if not ok:
        finding("devolucao", "médio", f"cancelar a fatura de um pedido já expedido foi recusado: {r.get('code')}: {r.get('message')}")
    else:
        st = one(f"SELECT status FROM sales.sales_order WHERE number = {n}")
        stock1 = float(one(f"SELECT sum(quantity) FROM inventory.stock_movement m JOIN base.product p ON p.id = m.product_id WHERE p.code = '{b['item']}'"))
        if st == "OPEN" and stock1 < stock0:
            finding("devolucao", "info", f"fatura cancelada: pedido {n} volta a OPEN e a mercadoria continua expedida (sai de novo sem nova baixa?)")
        d = delta(r0, recon())
        if d:
            finding("devolucao", "alto", f"conciliações mudaram após cancelar fatura: {d}")
    # Return of goods from a paid order.
    n2 = must("sales.create_order", customer=b["customer"], items=[{"product": b["item"], "quantity": 2}])["number"]
    must("logistics.ship", order=n2, carrier=b["carrier"])
    must("sales.invoice_order", number=n2)
    r1 = recon()
    last_bill = one("SELECT COALESCE(max(id), 0) FROM finance.bill")
    ret = must("logistics.register_return", customer=b["customer"], order=n2, items=[{"product": b["item"], "quantity": 1}], reason="vistoria")
    credit = sql(f"SELECT kind, amount, status FROM finance.bill WHERE party_id = {b['customer']} AND id > {last_bill} ORDER BY id")
    if not credit and not ret.get("credit"):
        finding("devolucao", "médio", f"devolução do pedido {n2} não gerou crédito/abatimento para o cliente: {json.dumps(ret, default=str)[:200]}")
    d = delta(r1, recon())
    if d:
        finding("devolucao", "alto", f"conciliações mudaram após a devolução: {d}")
    return {"cancelled": n, "returned": n2, "return": ret}


@trail
def compra(b):
    r0 = recon()
    approver, tok = T.new_user("admin")
    must("supply.save_supplier_item", product=b["item"], supplier=b["supplier"], price="20", lead_time_days=3, preferred=True)
    req = must("supply.request_purchase", reason="vistoria", product=b["item"], quantity=10)["number"]
    must("supply.approve_request", tok, request=req)
    po = must("supply.create_orders", requests=[req])["orders"][0]
    must("supply.receive", order=po, line=1, quantity=6)
    must("supply.receive", order=po, line=1, quantity=4)
    total = one(f"SELECT total FROM supply.purchase_order WHERE number = {po}")
    policy = one("SELECT supplier_invoice FROM supply.policy")
    ok, r, _ = run("supply.register_invoice", order=po, number=f"NF{SFX}", amount=str(total))
    if not ok and policy == "match":
        finding("compra", "médio", f"nota do fornecedor não registrada: {r.get('code')}: {r.get('message')}")
    payables = sql(f"SELECT document, amount, status FROM finance.bill WHERE kind = 'payable' AND party_id = {b['supplier']} ORDER BY id")
    if not payables:
        finding("compra", "alto", "recebimento não gerou título a pagar")
    else:
        statement_pay("CAIXA", [(f"PAG {doc} FORNECEDOR", -float(amount)) for doc, amount, _ in payables if _ == "open"])
        left = one(f"SELECT count(*) FROM finance.bill WHERE kind = 'payable' AND party_id = {b['supplier']} AND status = 'open'")
        if int(left):
            finding("compra", "alto", f"pagamento no extrato não baixou {left} título(s) a pagar sozinho: {payables}")
    must("supply.return_to_supplier", order=po, line=1, quantity=1, reason="avaria")
    d = delta(r0, recon())
    if d:
        finding("compra", "alto", f"conciliações mudaram após a compra: {d}")
    return {"request": req, "order": po, "payables": payables}


@trail
def producao(b):
    r0 = recon()
    comp, made = f"VPC{SFX}", f"VPM{SFX}"
    must("base.save_product", code=comp, description="Componente vistoria", price="5")
    must("base.save_product", code=made, description="Produto vistoria", price="90")
    must("inventory.stock_in", product=comp, quantity=50, warehouse="CENTRAL", unit_cost="5")
    must("production.save_item_plan", product=made, make_or_buy="make", lead_time_days=2, standard_cost="12")
    must("production.save_structure", product=made, lines=[{"component": comp, "quantity": 2}])
    wo = must("production.create_order", product=made, quantity=5, due_date=(datetime.date.today() + datetime.timedelta(days=5)).isoformat(),
              warehouse="CENTRAL")["order"]
    must("production.release_order", order=wo)
    must("production.issue_components", order=wo)
    ops = sql(f"SELECT seq FROM production.order_operation o JOIN production.work_order w ON w.id = o.order_id WHERE w.number = {wo}")
    for (seq,) in ops:
        must("production.report_operation", order=wo, seq=seq, hours=1, good_qty=5)
    must("production.deliver", order=wo, good_qty=5, complete=True)
    must("production.close_order", order=wo)
    d = delta(r0, recon())
    if d:
        finding("producao", "alto", f"conciliações mudaram após produzir e encerrar a OP {wo}: {d}")
    # Sell what was made.
    n = must("sales.create_order", customer=b["customer"], items=[{"product": made, "quantity": 2}])["number"]
    must("logistics.ship", order=n, carrier=b["carrier"])
    must("sales.invoice_order", number=n)
    d = delta(r0, recon())
    if d:
        finding("producao", "alto", f"conciliações mudaram após vender o produzido: {d}")
    return {"work_order": wo, "order": n, "operations": len(ops)}


@trail
def campo(b):
    r0 = recon()
    emp = must("projects.save_employee", name=f"Técnico Vistoria {SFX}", profile=one("SELECT code FROM projects.rate_profile LIMIT 1"),
               hourly_cost="40")["id"]
    must("inventory.stock_in", product=b["item"], quantity=5, warehouse="LAB", unit_cost="20")
    tech = must("field.save_technician", employee=emp, warehouse="LAB")
    tid = tech.get("id") or tech.get("technician") or emp
    so = must("field.open_order", customer=b["customer"], description="Manutenção vistoria", service=b["service"])
    num = so.get("number") or so.get("order")
    must("field.schedule", order=num, technician=tid, start=(datetime.datetime.now() + datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M"))
    must("field.start_trip", order=num)
    must("field.log_work", order=num, hours=2, km=10, technician=tid)
    must("field.use_part", order=num, product=b["item"], quantity=1, technician=tid)
    must("field.sign_off", order=num, signed_by="Cliente")
    inv = must("field.invoice_orders", orders=[num])
    bills = sql(f"SELECT document, amount FROM finance.bill WHERE kind = 'receivable' AND party_id = {b['customer']} AND status = 'open' "
                f"AND document LIKE '%{num}%' ORDER BY id")
    if not bills:
        finding("campo", "alto", f"OS {num} faturada sem título localizável pelo número ({json.dumps(inv, default=str)[:200]})")
    else:
        statement_pay("CAIXA", [(f"PIX {doc} CLIENTE", amount) for doc, amount in bills])
        left = one(f"SELECT count(*) FROM finance.bill WHERE kind = 'receivable' AND document LIKE '%{num}%' AND status = 'open'")
        if int(left):
            finding("campo", "alto", f"pagamento da OS {num} no extrato não baixou o título sozinho")
    d = delta(r0, recon())
    if d:
        finding("campo", "alto", f"conciliações mudaram após a OS {num}: {d}")
    return {"service_order": num, "invoice": inv}


@trail
def projetos(b):
    r0 = recon()
    code = f"PV{SFX}"
    prof = one("SELECT code FROM projects.rate_profile LIMIT 1")
    emp = must("projects.save_employee", name=f"Consultor Vistoria {SFX}", profile=prof, hourly_cost="60")["id"]
    must("projects.save_project", code=code, name="Projeto vistoria", customer=b["customer"], billing="hourly", manager="admin")
    must("projects.save_activity", project=code, code="1", name="Atividade", planned_hours=10)
    must("projects.allocate", project=code, activity="1", employee=emp, hours=4, week=datetime.date.today().isoformat())
    ok, r, _ = run("projects.approve_plan", project=code)
    if not ok:
        finding("projetos", "baixo", f"aprovar o plano: {r.get('code')}: {r.get('message')}")
        must("projects.approve_plan", project=code, low_margin_justification="vistoria das trilhas de processo")
    must("projects.log_time", project=code, task="1", hours=4, description="trabalho de vistoria", employee=emp)
    must("projects.approve_time", project=code)
    must("projects.post_expense", project=code, kind="other", description="Despesa refaturável", unit_cost="100", rebillable=True)
    inv = must("projects.invoice_project", project=code)
    bills = sql(f"SELECT document, amount FROM finance.bill WHERE id = {inv['bill']} AND status = 'open'")
    if not bills:
        finding("projetos", "alto", f"faturamento do projeto sem título localizável ({json.dumps(inv, default=str)[:200]})")
    else:
        statement_pay("CAIXA", [(f"TED {doc} CLIENTE", amount) for doc, amount in bills])
        left = one(f"SELECT count(*) FROM finance.bill WHERE id = {inv['bill']} AND status = 'open'")
        if int(left):
            finding("projetos", "alto", f"pagamento do projeto {code} no extrato não baixou sozinho")
    d = delta(r0, recon())
    if d:
        finding("projetos", "alto", f"conciliações mudaram após o projeto: {d}")
    return {"project": code, "invoice": inv}


@trail
def atendimento(b):
    """Spec 041 end to end: bought for the order → received → shipped → invoiced."""
    r0 = recon()
    item = f"VAT{SFX}"
    must("base.save_product", code=item, description="Item sob encomenda", price="70")
    must("supply.save_supplier_item", product=item, supplier=b["supplier"], price="30", lead_time_days=2, preferred=True)
    must("sales.fulfillment_policy", action="rule", product=item, mode="purchase")
    o = must("sales.create_order", customer=b["customer"], items=[{"product": item, "quantity": 4}])
    n, req = o["number"], o["supply"]["requests"][0]
    approver, tok = T.new_user("admin")
    must("supply.approve_request", tok, request=req)
    po = must("supply.create_orders", requests=[req])["orders"][0]
    rec = must("supply.receive", order=po)
    if one(f"SELECT fulfillment FROM sales.sales_order WHERE number = {n}") != "ok":
        finding("atendimento", "alto", f"pedido {n} não foi liberado ao receber a compra vinculada {po}")
    sh = must("logistics.ship", order=n, carrier=b["carrier"])
    if not sh.get("shipment"):
        finding("atendimento", "alto", f"pedido {n} não expediu depois do recebimento: {sh}")
    must("sales.invoice_order", number=n)
    d = delta(r0, recon())
    if d:
        finding("atendimento", "alto", f"conciliações mudaram: {d}")
    return {"order": n, "request": req, "po": po, "released": rec.get("released")}


@trail
def estoque(b):
    r0 = recon()
    must("inventory.write_off", product=b["item"], quantity=1, reason="quebra na vistoria")
    bal = float(one(f"SELECT sum(quantity) FROM inventory.stock_movement m JOIN base.product p ON p.id = m.product_id "
                    f"JOIN inventory.warehouse w ON w.id = m.warehouse_id WHERE p.code = '{b['item']}' AND w.code = 'CENTRAL'"))
    cnt = must("inventory.count", warehouse="CENTRAL", lines=[{"product": b["item"], "counted": bal - 2}], confirm=True)
    must("logistics.transfer", action="ship", from_wh="CENTRAL", to_wh="LAB", items=[{"product": b["item"], "quantity": 1}], notes="vistoria")
    d = delta(r0, recon())
    if d:
        finding("estoque", "alto", f"conciliações mudaram após baixa, inventário e transferência: {d}")
    return {"count": cnt}


@trail
def contabil(b):
    tb = must("finance.trial_balance")
    if not ledger_balanced():
        finding("contabil", "alto", "razão geral não fecha (débitos ≠ créditos)")
    bad = entries_unbalanced()
    if bad:
        finding("contabil", "alto", f"lançamentos desbalanceados: {bad}")
    r = must("finance.reconciliations")
    if r["differences"]:
        finding("contabil", "info", f"conciliações com diferença na base de dev (acumulado de testes): "
                                   f"{ {k: v for k, v in r['items'].items() if abs(float(v or 0)) >= 0.01} }")
    return {"trial_balance": {k: tb[k] for k in list(tb)[:4]} if isinstance(tb, dict) else None}


def flow_steps(flow, key, until=None, timeout=60):
    end = time.time() + timeout
    while True:
        rows = sql("SELECT s.code, x.status, x.how, x.reason, x.error::text, i.id, x.seq FROM flow.instance i JOIN flow.instance_step x ON x.instance_id = i.id "
                   f"JOIN flow.step s ON s.flow_code = i.flow_code AND s.seq = x.seq WHERE i.flow_code = '{flow}' AND i.doc_key = '{key}' ORDER BY x.seq")
        st = {r[0]: {"status": r[1], "how": r[2], "reason": r[3], "error": r[4], "instance": r[5], "seq": r[6]} for r in rows}
        if until is None or (st and until(st)) or time.time() > end:
            return st
        time.sleep(1)


def settled(st):
    return all(v["status"] in ("done", "skipped", "waiting", "failed") for v in st.values()) and any(v["status"] in ("waiting", "failed") for v in st.values())


def with_flow(flow, modes, body):
    saved = must("flows.configure", flow=flow)
    try:
        must("flows.configure", flow=flow, action="activate")
        for seq, mode in modes.items():
            must("flows.configure", flow=flow, action="mode", step=seq, mode=mode)
        return body()
    finally:
        must("flows.configure", flow=flow, action="activate" if saved["active"] else "deactivate")
        for st in saved["steps"]:
            if st["mode"] != "wait":
                must("flows.configure", flow=flow, action="mode", step=st["seq"], mode=st["mode"])


def describe(st):
    return "; ".join(f"{k}={v['status']}" + (f" ({(v['reason'] or '')[:90]})" if v["status"] == "waiting" else "")
                     + (f" ERRO {(v['error'] or '')[:160]}" if v["status"] == "failed" else "") for k, v in st.items())


@trail
def esteira_compra(b):
    def body():
        req = must("supply.request_purchase", reason="esteira vistoria", product=b["item"], quantity=3)["number"]
        st = flow_steps("purchase", str(req), settled, 60)
        print("   compra:", describe(st))
        if st.get("approve", {}).get("status") == "done":
            finding("esteira_compra", "alto", f"aprovação automática pelo robô aprovou a solicitação {req} sem alçada humana "
                                               f"(alçada do robô: {one('SELECT supply.approval_limit_of(' + chr(39) + 'system' + chr(39) + ', ' + chr(39) + 'admin' + chr(39) + ')')})")
        if st.get("receive", {}).get("status") == "done":
            finding("esteira_compra", "alto", f"recebimento automático deu entrada no estoque sem a mercadoria chegar (solicitação {req})")
        for k, v in st.items():
            if v["status"] == "failed":
                finding("esteira_compra", "médio", f"etapa {k} falhou em automático: {(v['error'] or '')[:200]}")
        return st
    return with_flow("purchase", {1: "auto", 2: "auto", 3: "auto"}, body)


@trail
def esteira_campo(b):
    def body():
        so = must("field.open_order", customer=b["customer"], description="Esteira campo vistoria", service=b["service"])
        num = so.get("number") or so.get("order")
        st = flow_steps("field", str(num), settled, 60)
        print("   campo:", describe(st))
        for k, v in st.items():
            if v["status"] == "failed":
                finding("esteira_campo", "alto", f"etapa {k} falha sempre em automático: {(v['error'] or '')[:200]}")
        return st
    return with_flow("field", {1: "auto", 3: "auto"}, body)


@trail
def esteira_producao(b):
    def body():
        comp, made = f"VEC{SFX}", f"VEM{SFX}"
        must("base.save_product", code=comp, description="Componente esteira", price="5")
        must("base.save_product", code=made, description="Produto esteira", price="90")
        must("inventory.stock_in", product=comp, quantity=20, warehouse="CENTRAL", unit_cost="5")
        must("production.save_item_plan", product=made, make_or_buy="make", lead_time_days=1)
        must("production.save_structure", product=made, lines=[{"component": comp, "quantity": 1}])
        wo = must("production.create_order", product=made, quantity=3, due_date=(datetime.date.today() + datetime.timedelta(days=3)).isoformat(),
                  warehouse="CENTRAL")["order"]
        st = flow_steps("production", str(wo), lambda s: s.get("make", {}).get("status") in ("waiting", "done") or settled(s), 60)
        print("   produção (antes de fabricar):", describe(st))
        must("production.deliver", order=wo, good_qty=3, complete=True)
        st = flow_steps("production", str(wo), lambda s: s.get("close", {}).get("status") in ("done", "failed"), 90)
        print("   produção (depois):", describe(st))
        if st.get("close", {}).get("status") != "done":
            finding("esteira_producao", "médio", f"OP {wo} entregue não encerrou sozinha: {describe(st)}")
        return st
    return with_flow("production", {1: "auto", 2: "auto", 4: "auto"}, body)


def report():
    print("\n=== achados ===")
    for t, s, x in FINDINGS:
        print(f"- [{t}] ({s}) {x}")
    if entries_unbalanced():
        print("- [geral] (alto) lançamentos desbalanceados:", entries_unbalanced())


if __name__ == "__main__":
    b = base()
    names = sys.argv[1:] or list(TRAILS)
    for name in names:
        print(f"\n== trilha {name}")
        try:
            out = TRAILS[name](b)
            print("  ok:", json.dumps(out, default=str)[:300])
        except Stop as e:
            finding(name, "alto", f"trilha interrompida: {e}")
        except Exception as e:  # the audit goes on; the failure is a finding of the script
            finding(name, "roteiro", f"erro no roteiro: {type(e).__name__}: {str(e)[:300]}")
    report()
