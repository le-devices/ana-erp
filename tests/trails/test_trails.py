# SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Business-process trails end to end (spec 042, T-042-08): each trail runs through the real programs with fresh data
and must leave every control reconciliation (customers, suppliers, credits, inventory, work in process, banks) exactly
as it found it, the ledger balanced, and its documents settled and linked — so a regression in any process shows up.
Run: make teste-trilhas (requires `make subir`)."""

import datetime
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "integration"))
import test_integration as T  # noqa: E402  (same helpers, users and cleanup as the integration suite)

SFX = T.SUFFIX[-6:]


def setUpModule():
    T.setUpModule()


def tearDownModule():
    T.tearDownModule()


class Trail(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.token = T.admin_token()
        b = cls
        b.customer = cls.must("base.save_party", name=f"Cliente Trilha {SFX}", state="SP")["id"]
        b.supplier = cls.must("base.save_party", name=f"Fornecedor Trilha {SFX}", kind="supplier", state="SP")["id"]
        b.item = f"TRI{SFX}"
        cls.must("base.save_product", code=b.item, description=f"Item trilha {SFX}", price="50")
        cls.must("inventory.stock_in", product=b.item, quantity=100, warehouse="CENTRAL", unit_cost="20")
        cls.must("inventory.stock_in", product=b.item, quantity=10, warehouse="LAB", unit_cost="20")
        b.service = f"TSV{SFX}"
        cls.must("base.save_product", code=b.service, description=f"Serviço trilha {SFX}", price="80", kind="service")
        b.carrier = cls.must("logistics.save_carrier", name=f"Transp Trilha {SFX}")["id"]
        cls.must("supply.save_supplier_item", product=b.item, supplier=b.supplier, price="20", lead_time_days=3, preferred=True)
        b.approver, b.approver_token = T.new_user("admin")

    # ------------------------------------------------------------------ helpers
    @classmethod
    def run_(cls, program, token=None, **params):
        s, c, _ = T.http("POST", f"/api/programs/{program}/run", {"params": params}, token or cls.token)
        return c

    @classmethod
    def must(cls, program, token=None, **params):
        c = cls.run_(program, token, **params)
        if "error" in c:
            raise AssertionError(f"{program}: {c['error'].get('code')}: {c['error'].get('message')}")
        return c["result"]

    def sql(self, q):
        s, c, _ = T.http("POST", "/api/sql", {"sql": q}, self.token)
        self.assertEqual(s, 200, c)
        return c["rows"]

    def one(self, q):
        rows = self.sql(q)
        return rows[0][0] if rows else None

    def recon(self):
        return {k: round(float(v or 0), 2) for k, v in self.must("finance.reconciliations")["items"].items()}

    def assertUnchanged(self, before, trail):
        after = self.recon()
        moved = {k: round(after.get(k, 0) - before.get(k, 0), 2) for k in after if abs(after.get(k, 0) - before.get(k, 0)) >= 0.01}
        self.assertEqual(moved, {}, f"{trail}: conciliações de controle mudaram")
        bad = self.sql("SELECT e.id, e.memo FROM finance.journal_entry e JOIN finance.journal_line l ON l.entry_id = e.id "
                       "WHERE e.id > (SELECT max(id) - 5000 FROM finance.journal_entry) GROUP BY e.id, e.memo "
                       "HAVING round(sum(l.debit) - sum(l.credit), 2) <> 0 LIMIT 5")
        self.assertEqual(bad, [], f"{trail}: lançamentos desbalanceados")

    def pay(self, lines):
        """The money arrives (or leaves) in the bank statement with the document's number: it settles by itself."""
        day = T.ana_today().strftime("%d/%m/%Y")
        csv = "data;histórico;valor\n" + "".join(f"{day};{desc};{str(a).replace('.', ',')}\n" for desc, a in lines)
        return self.must("finance.import_statement", bank_account="CAIXA", format="csv", content=csv)

    def open_bills(self, where):
        return int(self.one(f"SELECT count(*) FROM finance.bill WHERE status = 'open' AND ({where})"))

    # ------------------------------------------------------------------ trails
    def test_venda(self):
        r0 = self.recon()
        n = self.must("sales.create_order", customer=self.customer,
                      items=[{"product": self.item, "quantity": 3}, {"product": self.service, "quantity": 1}])["number"]
        sh = self.must("logistics.ship", order=n, carrier=self.carrier)
        self.assertTrue(sh.get("shipment"), sh)
        self.must("logistics.deliver", shipment=sh["shipment"], received_by="Fulano")
        self.must("sales.invoice_order", number=n)
        bills = self.sql(f"SELECT document, amount FROM finance.bill WHERE document = 'ORD-{n}' OR document LIKE 'ORD-{n}/%'")
        self.assertTrue(bills, "pedido faturado sem título")
        self.pay([(f"PIX {doc} CLIENTE", a) for doc, a in bills])
        self.assertEqual(self.open_bills(f"document = 'ORD-{n}' OR document LIKE 'ORD-{n}/%'"), 0, "o PIX não baixou o título")
        v = self.must("docs.view", kind="order", key=str(n))
        self.assertGreaterEqual((v["shipments"], v["bills"]), (1, 1))
        self.assertUnchanged(r0, "venda")

    def test_devolucao(self):
        r0 = self.recon()
        n = self.must("sales.create_order", customer=self.customer, items=[{"product": self.item, "quantity": 2}])["number"]
        self.must("logistics.ship", order=n, carrier=self.carrier)
        self.must("sales.invoice_order", number=n)
        self.must("sales.cancel_invoice", number=n, reason="trilha")
        n2 = self.must("sales.create_order", customer=self.customer, items=[{"product": self.item, "quantity": 2}])["number"]
        self.must("logistics.ship", order=n2, carrier=self.carrier)
        self.must("sales.invoice_order", number=n2)
        self.must("logistics.register_return", customer=self.customer, order=n2, items=[{"product": self.item, "quantity": 1}], reason="trilha")
        self.assertUnchanged(r0, "devolução")

    def test_compra(self):
        r0 = self.recon()
        req = self.must("supply.request_purchase", reason="trilha", product=self.item, quantity=10)["number"]
        self.must("supply.approve_request", self.approver_token, request=req)
        po = self.must("supply.create_orders", requests=[req])["orders"][0]
        self.must("supply.receive", order=po, line=1, quantity=6)
        self.must("supply.receive", order=po, line=1, quantity=4)
        pay = self.sql(f"SELECT b.document, b.amount FROM finance.bill b JOIN supply.receipt r ON r.bill_id = b.id "
                       f"JOIN supply.purchase_order o ON o.id = r.order_id WHERE o.number = {po} AND b.status = 'open'")
        self.assertEqual(len(pay), 2, "cada recebimento gera seu título a pagar")
        self.pay([(f"PAG {doc} FORNECEDOR", -float(a)) for doc, a in pay])
        self.assertEqual(self.open_bills(f"document LIKE 'OC-{po}/%'"), 0, "o pagamento no extrato não baixou os títulos")
        self.must("supply.return_to_supplier", order=po, line=1, quantity=1, reason="avaria")
        acts = [i for e in self.run_("docs.view", kind="bill", key=str(self.one(f"SELECT max(id) FROM finance.bill WHERE document LIKE 'OC-{po}/%'")))["events"]
                if e.get("kind") == "actions" for i in e["data"]["items"]]
        self.assertIn({"kind": "purchase_order", "key": str(po)}, [a.get("params") for a in acts], "o título leva à ordem de compra")
        self.assertUnchanged(r0, "compra")

    def test_producao(self):
        r0 = self.recon()
        comp, made = f"TPC{SFX}", f"TPM{SFX}"
        self.must("base.save_product", code=comp, description="Componente trilha", price="5")
        self.must("base.save_product", code=made, description="Produto trilha", price="90")
        self.must("inventory.stock_in", product=comp, quantity=50, warehouse="CENTRAL", unit_cost="5")
        self.must("production.save_item_plan", product=made, make_or_buy="make", lead_time_days=2, standard_cost="12")
        self.must("production.save_structure", product=made, lines=[{"component": comp, "quantity": 2}])
        wo = self.must("production.create_order", product=made, quantity=5, warehouse="CENTRAL",
                       due_date=(T.ana_today() + datetime.timedelta(days=5)).isoformat())["order"]
        self.must("production.release_order", order=wo)
        self.must("production.issue_components", order=wo)
        for (seq,) in self.sql(f"SELECT o.seq FROM production.order_operation o JOIN production.work_order w ON w.id = o.order_id WHERE w.number = {wo}"):
            self.must("production.report_operation", order=wo, seq=seq, hours=1, good_qty=5)
        self.must("production.deliver", order=wo, good_qty=5, complete=True)
        self.must("production.close_order", order=wo)
        n = self.must("sales.create_order", customer=self.customer, items=[{"product": made, "quantity": 2}])["number"]
        self.must("logistics.ship", order=n, carrier=self.carrier)
        self.must("sales.invoice_order", number=n)
        self.assertUnchanged(r0, "produção")

    def test_campo(self):
        r0 = self.recon()
        prof = self.one("SELECT code FROM projects.rate_profile LIMIT 1")
        emp = self.must("projects.save_employee", name=f"Técnico Trilha {SFX}", profile=prof, hourly_cost="40")["id"]
        self.must("field.save_technician", employee=emp, warehouse="LAB")
        so = self.must("field.open_order", customer=self.customer, description="Manutenção trilha", service=self.service)
        num = so.get("number") or so.get("order")
        self.must("field.schedule", order=num, technician=emp,
                  start=(T.ana_now() + datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M"))
        self.must("field.start_trip", order=num)
        self.must("field.log_work", order=num, hours=2, km=10)                    # the scheduled technician (B-01)
        self.must("field.use_part", order=num, product=self.item, quantity=1)
        self.must("field.sign_off", order=num, signed_by="Cliente")
        self.must("field.invoice_orders", orders=[num])
        bills = self.sql(f"SELECT document, amount FROM finance.bill WHERE document LIKE 'OS-{num}%' AND status = 'open'")
        self.assertTrue(bills, "OS faturada sem título")
        self.pay([(f"PIX {doc} CLIENTE", a) for doc, a in bills])
        self.assertEqual(self.open_bills(f"document LIKE 'OS-{num}%'"), 0)
        self.assertUnchanged(r0, "serviço em campo")

    def test_projeto(self):
        r0 = self.recon()
        code = f"PT{SFX}"
        prof = self.one("SELECT code FROM projects.rate_profile LIMIT 1")
        emp = self.must("projects.save_employee", name=f"Consultor Trilha {SFX}", profile=prof, hourly_cost="60")["id"]
        self.must("projects.save_project", code=code, name="Projeto trilha", customer=self.customer, billing="hourly", manager="admin")
        self.must("projects.save_activity", project=code, code="1", name="Atividade", planned_hours=10)
        self.must("projects.allocate", project=code, activity="1", employee=emp, hours=4, week=T.ana_today().isoformat())
        if "error" in self.run_("projects.approve_plan", project=code):
            self.must("projects.approve_plan", project=code, low_margin_justification="trilha automática de processo")
        self.must("projects.log_time", project=code, task="1", hours=4, description="trabalho da trilha", employee=emp)
        self.must("projects.approve_time", project=code)
        self.must("projects.post_expense", project=code, kind="other", description="Despesa refaturável", unit_cost="100", rebillable=True)
        inv = self.must("projects.invoice_project", project=code)
        doc, amount = self.sql(f"SELECT document, amount FROM finance.bill WHERE id = {inv['bill']}")[0]
        self.pay([(f"TED {doc} CLIENTE", amount)])
        self.assertEqual(self.open_bills(f"id = {inv['bill']}"), 0)
        self.assertEqual(self.must("docs.view", kind="project_invoice", key=str(inv["number"]))["number"], inv["number"])
        self.assertUnchanged(r0, "projeto")

    def test_atendimento_sob_encomenda(self):
        r0 = self.recon()
        item = f"TAT{SFX}"
        self.must("base.save_product", code=item, description="Item sob encomenda", price="70")
        self.must("supply.save_supplier_item", product=item, supplier=self.supplier, price="30", lead_time_days=2, preferred=True)
        self.must("sales.fulfillment_policy", action="rule", product=item, mode="purchase")
        o = self.must("sales.create_order", customer=self.customer, items=[{"product": item, "quantity": 4}])
        n, req = o["number"], o["supply"]["requests"][0]
        self.must("supply.approve_request", self.approver_token, request=req)
        po = self.must("supply.create_orders", requests=[req])["orders"][0]
        self.must("supply.receive", order=po)
        self.assertEqual(self.one(f"SELECT fulfillment FROM sales.sales_order WHERE number = {n}"), "ok", "o recebimento não liberou o pedido")
        self.assertTrue(self.must("logistics.ship", order=n, carrier=self.carrier).get("shipment"))
        self.must("sales.invoice_order", number=n)
        self.assertUnchanged(r0, "atendimento sob encomenda")

    def test_estoque(self):
        r0 = self.recon()
        self.must("inventory.write_off", product=self.item, quantity=1, reason="quebra na trilha")
        bal = float(self.one(f"SELECT sum(m.quantity) FROM inventory.stock_movement m JOIN base.product p ON p.id = m.product_id "
                             f"JOIN inventory.warehouse w ON w.id = m.warehouse_id WHERE p.code = '{self.item}' AND w.code = 'CENTRAL'"))
        self.must("inventory.count", warehouse="CENTRAL", lines=[{"product": self.item, "counted": bal - 2}], confirm=True)
        self.must("logistics.transfer", action="ship", from_wh="CENTRAL", to_wh="LAB", items=[{"product": self.item, "quantity": 1}],
                  notes="trilha")
        self.assertUnchanged(r0, "estoque")

    # ------------------------------------------------------------------ flows with automatic steps
    def flow_steps(self, flow, key, until, timeout=90):
        end = time.time() + timeout
        while True:
            rows = self.sql("SELECT s.code, x.status, x.reason FROM flow.instance i JOIN flow.instance_step x ON x.instance_id = i.id "
                            f"JOIN flow.step s ON s.flow_code = i.flow_code AND s.seq = x.seq WHERE i.flow_code = '{flow}' "
                            f"AND i.doc_key = '{key}' ORDER BY x.seq")
            st = {r[0]: (r[1], r[2]) for r in rows}
            if (st and until(st)) or time.time() > end:
                return st
            time.sleep(1)

    def with_flow(self, flow, modes, body):
        saved = self.must("flows.configure", flow=flow)
        try:
            self.must("flows.configure", flow=flow, action="activate")
            for seq, mode in modes.items():
                self.must("flows.configure", flow=flow, action="mode", step=seq, mode=mode)
            body()
        finally:
            self.must("flows.configure", flow=flow, action="activate" if saved["active"] else "deactivate")
            for st in saved["steps"]:
                if st["mode"] != "wait":
                    self.must("flows.configure", flow=flow, action="mode", step=st["seq"], mode=st["mode"])

    def test_esteira_compra(self):
        e = self.run_("flows.configure", flow="purchase", action="mode", step=3, mode="auto")["error"]
        self.assertEqual(e["code"], "STEP_NOT_AUTOMATIC")                                  # receiving is physical (A-01)

        def body():
            req = self.must("supply.request_purchase", reason="esteira trilha", product=self.item, quantity=3)["number"]
            st = self.flow_steps("purchase", str(req), lambda s: s.get("approve", ("",))[0] in ("waiting", "failed"))
            self.assertEqual(st["approve"][0], "waiting", st)                              # the robot has no limit: a person (A-04)
            self.must("supply.approve_request", self.approver_token, request=req)
            st = self.flow_steps("purchase", str(req), lambda s: s.get("receive", ("",))[0] == "waiting")
            self.assertEqual((st["order"][0], st["receive"][0]), ("done", "waiting"), st)  # ordered by itself, waits for the goods
            po = int(self.one(f"SELECT max(o.number) FROM supply.purchase_order o JOIN supply.purchase_order_line l ON l.order_id = o.id "
                              f"JOIN supply.purchase_request r ON r.id = l.request_id WHERE r.number = {req}"))
            self.must("supply.receive", order=po)
            st = self.flow_steps("purchase", str(req), lambda s: s.get("payment", ("",))[0] == "waiting")
            pay = self.sql(f"SELECT b.document, b.amount FROM finance.bill b JOIN supply.receipt r ON r.bill_id = b.id "
                           f"JOIN supply.purchase_order o ON o.id = r.order_id WHERE o.number = {po} AND b.status = 'open'")
            self.pay([(f"PAG {d} FORNECEDOR", -float(a)) for d, a in pay])
            st = self.flow_steps("purchase", str(req), lambda s: s.get("payment", ("",))[0] == "done")
            self.assertEqual({k: v[0] for k, v in st.items()}, {"approve": "done", "order": "done", "receive": "done", "payment": "done"}, st)
        r0 = self.recon()
        self.with_flow("purchase", {1: "auto", 2: "auto"}, body)
        self.assertUnchanged(r0, "esteira de compra")

    def test_esteira_campo(self):
        e = self.run_("flows.configure", flow="field", action="mode", step=1, mode="auto")["error"]
        self.assertEqual(e["code"], "STEP_NOT_AUTOMATIC")                                  # someone chooses the technician (A-03)
        prof = self.one("SELECT code FROM projects.rate_profile LIMIT 1")
        emp = self.must("projects.save_employee", name=f"Técnico Esteira {SFX}", profile=prof, hourly_cost="40")["id"]
        self.must("field.save_technician", employee=emp, warehouse="LAB")

        def body():
            so = self.must("field.open_order", customer=self.customer, description="Esteira campo trilha", service=self.service)
            num = so.get("number") or so.get("order")
            self.must("field.schedule", order=num, technician=emp,
                      start=(T.ana_now() + datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M"))
            self.must("field.start_trip", order=num)
            self.must("field.log_work", order=num, hours=2, km=10)
            self.must("field.sign_off", order=num, signed_by="Cliente")
            st = self.flow_steps("field", str(num), lambda s: s.get("receipt", ("",))[0] == "waiting")
            self.assertEqual(st["receipt"][0], "waiting", st)                              # invoiced and charged by itself
            bills = self.sql(f"SELECT document, amount FROM finance.bill WHERE document LIKE 'OS-{num}%' AND status = 'open'")
            self.pay([(f"PIX {d} CLIENTE", a) for d, a in bills])
            st = self.flow_steps("field", str(num), lambda s: s.get("receipt", ("",))[0] == "done")
            self.assertEqual(st["receipt"][0], "done", st)
        r0 = self.recon()
        self.with_flow("field", {3: "auto"}, body)
        self.assertUnchanged(r0, "esteira de serviço em campo")

    def test_esteira_producao(self):
        def body():
            comp, made = f"TEC{SFX}", f"TEM{SFX}"
            self.must("base.save_product", code=comp, description="Componente esteira", price="5")
            self.must("base.save_product", code=made, description="Produto esteira", price="90")
            self.must("inventory.stock_in", product=comp, quantity=20, warehouse="CENTRAL", unit_cost="5")
            self.must("production.save_item_plan", product=made, make_or_buy="make", lead_time_days=1)
            self.must("production.save_structure", product=made, lines=[{"component": comp, "quantity": 1}])
            wo = self.must("production.create_order", product=made, quantity=3, warehouse="CENTRAL",
                           due_date=(T.ana_today() + datetime.timedelta(days=3)).isoformat())["order"]
            st = self.flow_steps("production", str(wo), lambda s: s.get("make", ("",))[0] == "waiting")
            self.assertEqual((st["release"][0], st["issue"][0], st["make"][0]), ("done", "done", "waiting"), st)
            self.must("production.deliver", order=wo, good_qty=3, complete=True)
            st = self.flow_steps("production", str(wo), lambda s: s.get("close", ("",))[0] == "done")
            self.assertEqual(st["close"][0], "done", st)
        r0 = self.recon()
        self.with_flow("production", {1: "auto", 2: "auto", 4: "auto"}, body)
        self.assertUnchanged(r0, "esteira de produção")


if __name__ == "__main__":
    unittest.main()
