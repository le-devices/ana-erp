# ana:description Conciliações automáticas: cada razão auxiliar (clientes, fornecedores, estoque…) contra a contabilidade, com o que diverge
# ana:exposed yes
# ana:command conciliacoes
# ana:category Contabilidade/Lançamentos e fechamento
"""Spec 038 (RF-038-04, RNF-038-05). One look answers "does everything match?": green when the
difference is zero; otherwise it says what diverges and opens the documents that explain it."""

from decimal import Decimal

from ana_lib.docs.common import link

PARAMS = {
    "key": {"type": "str", "label": "conciliação (vazio = todas)"},
}
ME = "finance.reconciliations"
CONTROL = ("customers", "suppliers", "customer_credits", "supplier_credits", "supplier_advances")
CENT = Decimal("0.01")


def main(key=None):
    rows = ana.sql("SELECT key, label, account, subledger, ledger, difference, items FROM finance.reconciliation()")
    if key:
        r = next((x for x in rows if x["key"] == key), None)
        if not r:
            raise ana.Error("NOT_FOUND", f"conciliação {key} não existe")
        return detail(r)
    bad = [r for r in rows if abs(r["difference"] or 0) >= CENT]
    ana.metrics([{"label": "Conciliações", "value": len(rows)},
                 {"label": "Batendo", "value": len(rows) - len(bad), "status": "ok"},
                 {"label": "Com diferença", "value": len(bad), "status": "bad" if bad else "ok",
                  "hint": "tudo batendo" if not bad else "abra a linha para ver o que diverge"}],
                title="Está tudo batendo?")
    ana.table([{"conciliação": r["label"], "conta": r["account"],
                "razão auxiliar": q2(r["subledger"]), "contabilidade": q2(r["ledger"]), "diferença": q2(r["difference"]),
                "itens": r["items"],
                "situação": "batendo" if abs(r["difference"] or 0) < CENT else "DIVERGENTE",
                "_actions": [{"label": "Detalhar", "program": ME, "params": {"key": r["key"]}, "open": True}]} for r in rows],
              title="Razões auxiliares × contabilidade")
    if not opening_done() and any(r["key"] in ("inventory", "work_in_process") and abs(r["difference"]) >= CENT for r in rows):
        ana.actions([{"label": "Ajuste inicial de estoque", "program": "finance.inventory_opening_adjustment", "open": True}],
                    title="Estoque ainda sem ajuste inicial")
    ana.actions([{"label": "Fontes automáticas de extrato (pasta OFX/CNAB ou API do banco)", "program": "finance.statement_sources",
                  "open": True},
                 {"label": "Regras do extrato (tarifas, IOF, rendimentos)", "program": "finance.statement_rules", "open": True},
                 {"label": "Tolerância e compensação automática", "program": "finance.settlement_policy", "open": True},
                 {"label": "Compensar créditos agora", "program": "finance.offset_credits"}],
                title="O que concilia sozinho")
    return {"total": len(rows), "differences": len(bad), "items": {r["key"]: r["difference"] for r in rows}}


def q2(v):
    return None if v is None else Decimal(v).quantize(CENT)


def brl(v):
    if v is None:
        return "—"
    return "R$ " + f"{Decimal(v):,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


def opening_done():
    return bool(ana.sql_value("SELECT EXISTS (SELECT 1 FROM finance.journal_entry WHERE document = 'AJUSTE-ESTOQUE-INICIAL')"))


def manual_entries(account):
    rows = ana.sql(
        "SELECT e.id, e.entry_date, e.memo, e.document, e.created_by, sum(l.debit - l.credit) AS amount "
        "FROM finance.journal_entry e JOIN finance.journal_line l ON l.entry_id = e.id "
        "WHERE e.manual AND l.account = $1 GROUP BY e.id ORDER BY e.entry_date DESC, e.id DESC LIMIT 200", account)
    if rows:
        ana.table([{"lançamento": r["id"], "data": r["entry_date"], "histórico": r["memo"], "documento": r["document"],
                    "por": r["created_by"], "valor na conta": r["amount"]} for r in rows],
                  title="Lançamentos manuais nesta conta (causa comum de diferença: corrija pelo documento, não por lançamento)")
    return len(rows)


def detail(r):
    ok = abs(r["difference"] or 0) < CENT
    ana.metrics([{"label": "Razão auxiliar", "value": brl(r["subledger"])},
                 {"label": "Contabilidade", "value": brl(r["ledger"])},
                 {"label": "Diferença", "value": brl(r["difference"]), "status": "ok" if ok else "bad",
                  "hint": "batendo" if ok else "veja abaixo o que explica a diferença"}], title=r["label"])
    k = r["key"]
    if k in CONTROL:
        rows = ana.sql(
            "SELECT b.id, b.document, p.name, b.due_date, b.amount, b.entry_id, "
            "  (SELECT COALESCE(sum(l.debit - l.credit), 0) FROM finance.journal_line l WHERE l.entry_id = b.entry_id AND l.account = b.account) AS posted "
            "FROM finance.bill b JOIN base.party p ON p.id = b.party_id "
            "WHERE b.status = 'open' AND b.account = $1 AND (b.entry_id IS NULL OR NOT EXISTS ("
            "  SELECT 1 FROM finance.journal_line l WHERE l.entry_id = b.entry_id AND l.account = b.account)) "
            "ORDER BY b.id LIMIT 300", r["account"])
        ana.table([{"título": x["document"], "parceiro": x["name"], "vencimento": x["due_date"], "valor": x["amount"],
                    "problema": "sem lançamento" if x["entry_id"] is None else "lançamento não usa a conta de controle"} for x in rows],
                  title="Títulos em aberto sem lançamento na conta de controle")
        # Spec 042 (M-01): settled without any settlement on record (statement, offset, charge, residual) — the control
        # account still holds them, the subledger no longer does.
        loose = ana.sql(
            "WITH ev AS (SELECT bill_id, amount FROM finance.bank_match UNION ALL SELECT credit_bill, amount FROM finance.offset "
            "  UNION ALL SELECT debit_bill, amount FROM finance.offset "
            "  UNION ALL SELECT bill_id, amount FROM finance.charge WHERE status = 'paid' AND entry_id IS NOT NULL "
            "  UNION ALL SELECT parent_bill_id, amount FROM finance.bill WHERE parent_bill_id IS NOT NULL) "
            "SELECT b.id, b.document, p.name, b.amount, b.amount - COALESCE((SELECT sum(amount) FROM ev WHERE ev.bill_id = b.id), 0) AS missing "
            "FROM finance.bill b JOIN base.party p ON p.id = b.party_id WHERE b.status = 'settled' AND b.account = $1 "
            "AND round(b.amount - COALESCE((SELECT sum(amount) FROM ev WHERE ev.bill_id = b.id), 0), 2) <> 0 ORDER BY b.id LIMIT 300",
            r["account"])
        if loose:
            ana.table([{"título": x["document"], "parceiro": x["name"], "valor": x["amount"], "sem baixa registrada": x["missing"],
                        "_open": link("bill", x["id"])} for x in loose],
                      title="Títulos baixados sem baixa registrada (extrato, compensação ou cobrança) — a conta de controle ainda os tem")
        n = manual_entries(r["account"])
        return {"key": k, "bills": len(rows), "manual_entries": n, "settled_without_record": len(loose)}
    if k == "inventory":
        rows = ana.sql(
            "SELECT p.code, p.description, c.quantity, c.avg_cost, c.value FROM inventory.item_cost c JOIN base.product p ON p.id = c.product_id "
            "WHERE c.quantity <> 0 OR c.value <> 0 ORDER BY c.value DESC LIMIT 300")
        ana.table([{"item": x["code"], "descrição": x["description"], "quantidade": x["quantity"], "custo médio": x["avg_cost"],
                    "valor": x["value"]} for x in rows], title="Valor do estoque por item (custo médio)")
        n = manual_entries(r["account"])
        if not ok and not opening_done():
            ana.actions([{"label": "Ajuste inicial de estoque", "program": "finance.inventory_opening_adjustment", "open": True}],
                        title="Diferença herdada de antes da valorização")
        return {"key": k, "items": len(rows), "manual_entries": n}
    if k == "goods_received":
        rows = ana.sql(
            "SELECT o.number, p.name, r.received_at, r.total AS value, r.invoice_id FROM supply.receipt r "
            "JOIN supply.purchase_order o ON o.id = r.order_id JOIN base.party p ON p.id = o.supplier_id "
            "WHERE r.bill_id IS NULL AND r.total > 0 ORDER BY r.received_at LIMIT 300")
        ana.table([{"ordem": x["number"], "fornecedor": x["name"], "recebido em": x["received_at"], "valor": x["value"],
                    "nota": "pendente de decisão" if x["invoice_id"] else "não chegou"} for x in rows],
                  title="Recebimentos ainda sem título do fornecedor")
        pending = ana.sql(
            "SELECT i.id, i.number AS document, p.name, i.amount, i.reason FROM supply.supplier_invoice i JOIN base.party p ON p.id = i.supplier_id "
            "WHERE i.status = 'pending' ORDER BY i.id LIMIT 300")
        if pending:
            ana.table([{"nota": x["document"], "fornecedor": x["name"], "valor": x["amount"], "motivo": x["reason"],
                        "_actions": [{"label": "Decidir", "program": "supply.invoices", "open": True}]} for x in pending],
                      title="Notas de fornecedor aguardando decisão (fora da tolerância)")
        return {"key": k, "receipts": len(rows), "pending_invoices": len(pending), "manual_entries": manual_entries(r["account"])}
    if k == "gateway_receivable":
        rows = ana.sql("SELECT c.id, c.connector, c.external_id, c.amount, c.net, c.paid_at FROM finance.charge c "
                       "WHERE c.status = 'paid' AND c.payout_line_id IS NULL AND c.net IS NOT NULL ORDER BY c.paid_at LIMIT 300")
        ana.table([{"cobrança": x["id"], "gateway": x["connector"], "identificador": x["external_id"], "valor": x["amount"],
                    "líquido": x["net"], "paga em": x["paid_at"]} for x in rows],
                  title="Cobranças pagas aguardando o repasse do gateway no extrato")
        return {"key": k, "charges": len(rows), "manual_entries": manual_entries(r["account"])}
    if k.startswith("bank:"):
        code = k[5:]
        rows = ana.sql("SELECT l.id, l.posted_on, l.description, l.document, l.amount FROM finance.bank_statement_line l "
                       "WHERE l.bank_account = $1 AND l.status = 'open' ORDER BY l.posted_on, l.id LIMIT 300", code)
        ana.table([{"data": x["posted_on"], "histórico": x["description"], "documento": x["document"], "valor": x["amount"]} for x in rows],
                  title="Linhas do extrato ainda sem lançamento")
        ana.actions([{"label": "Conciliar agora", "program": "finance.reconcile", "params": {"bank_account": code}},
                     {"label": "Bancada de conciliação", "program": "finance.reconciliation", "params": {"bank_account": code}, "open": True},
                     {"label": "Criar regra para tarifas e rendimentos", "program": "finance.statement_rules", "open": True}],
                    title="Como zerar")
        return {"key": k, "open_lines": len(rows), "manual_entries": manual_entries(r["account"])}
    if k == "work_in_process":
        rows = ana.sql(
            "SELECT o.number, o.status, "
            "  COALESCE((SELECT -sum(value) FROM inventory.stock_movement m WHERE m.document = 'OP-' || o.number AND m.reason = 'production_issue'), 0) AS issued, "
            "  COALESCE((SELECT sum(cost) FROM production.operation_report r WHERE r.order_id = o.id), 0) AS hours, "
            "  COALESCE((SELECT sum(value) FROM inventory.stock_movement m WHERE m.document = 'OP-' || o.number AND m.reason = 'production_receipt'), 0) AS delivered "
            "FROM production.work_order o WHERE o.status NOT IN ('closed', 'cancelled', 'planned') ORDER BY o.number LIMIT 300")
        ana.table([{"ordem": x["number"], "situação": x["status"], "componentes": x["issued"], "horas": x["hours"],
                    "entregue": x["delivered"], "em elaboração": x["issued"] + x["hours"] - x["delivered"],
                    "_open": link("work_order", x["number"])} for x in rows],
                  title="Ordens de produção abertas")
        return {"key": k, "orders": len(rows), "manual_entries": manual_entries(r["account"])}
    if k == "bills_without_entry":
        rows = ana.sql("SELECT b.document, b.kind, p.name, b.amount, b.issue_date FROM finance.bill b JOIN base.party p ON p.id = b.party_id "
                       "WHERE b.entry_id IS NULL AND b.status <> 'cancelled' ORDER BY b.id LIMIT 300")
        ana.table([{"título": x["document"], "tipo": "a receber" if x["kind"] == "receivable" else "a pagar", "parceiro": x["name"],
                    "valor": x["amount"], "emissão": x["issue_date"]} for x in rows], title="Títulos sem lançamento")
        return {"key": k, "bills": len(rows)}
    if k == "movements_without_entry":
        rows = ana.sql(
            "SELECT m.id, m.document, m.reason, p.code, m.quantity, m.value, m.created_at FROM inventory.stock_movement m "
            "JOIN base.product p ON p.id = m.product_id JOIN inventory.posting_rule r ON r.reason = m.reason "
            "WHERE r.counter_key IS NOT NULL AND m.entry_id IS NULL AND m.value <> 0 "
            "  AND m.created_at > (SELECT COALESCE(max(applied_at), now()) FROM ana_system.migration WHERE name = '037_inventory_valuation') "
            "ORDER BY m.id DESC LIMIT 300")
        ana.table([{"documento": x["document"], "motivo": x["reason"], "item": x["code"], "quantidade": x["quantity"],
                    "valor": x["value"], "quando": x["created_at"]} for x in rows], title="Movimentações valorizadas sem lançamento")
        return {"key": k, "movements": len(rows)}
    if k == "freight_without_bill":
        rows = ana.sql(
            "SELECT s.number, c.name AS carrier, s.freight_cost, s.shipped_at FROM logistics.shipment s "
            "LEFT JOIN logistics.carrier c ON c.id = s.carrier_id WHERE s.freight_cost > 0 AND s.freight_bill_id IS NULL "
            "  AND s.status <> 'cancelled' AND s.created_at > (SELECT COALESCE(max(applied_at), now()) FROM ana_system.migration "
            "  WHERE name = '037_inventory_valuation') ORDER BY s.number LIMIT 300")
        ana.table([{"expedição": x["number"], "transportadora": x["carrier"], "frete": x["freight_cost"], "despachada": x["shipped_at"],
                    "_open": link("shipment", x["number"])} for x in rows],
                  title="Expedições com frete sem título da transportadora")
        return {"key": k, "shipments": len(rows)}
    return {"key": k}
