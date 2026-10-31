# ana:description Concilia no extrato os títulos de um documento (pedido, OS, compra): a etapa de recebimento ou pagamento da esteira
# ana:exposed yes
# ana:category Financeiro/Conciliação bancária
"""T-030-06b. The receipt (sales, field) and payment (purchase) stages of the esteiras run this program instead
of only waiting: the document's open bills are looked for in the open statement lines of every active bank
account, with the rules of the bank reconciliation (finance.reconcile_rules). Only what is certain is settled —
the charge's id or the bill's document in the line, with the exact amount, one line for one bill. A line that
matches only by amount and date is never settled here: the step waits and says which credit may be it, for a
person to confirm in the workbench. Payments that arrive later are settled by the statement import (spec 038)
and the esteira moves on by itself."""

from decimal import Decimal

from ana_lib.finance import banking, reconcile_rules

PARAMS = {
    "flow": {"type": "str", "required": True, "label": "esteira", "choices": [["sales", "Venda"], ["field", "Atendimento"],
                                                                                 ["purchase", "Compra"]]},
    "key": {"type": "str", "required": True, "label": "documento (nº)"},
    "tolerance_days": {"type": "int", "default": 5, "label": "tolerância de data para sugestões (dias)"},
}

SURE = Decimal("0.9")


def document_bills(flow, key):
    if flow == "sales":
        return ana.sql("SELECT id, kind, amount, document FROM flow.document_bills('ORD-' || $1) WHERE status = 'open' ORDER BY id",
                       key)
    if flow == "field":
        return ana.sql("SELECT id, kind, amount, document FROM flow.document_bills('OS-' || $1) WHERE status = 'open' ORDER BY id",
                       key)
    if flow == "purchase":
        return ana.sql("SELECT DISTINCT b.id, b.kind, b.amount, b.document FROM supply.purchase_order_line l "
                       "JOIN supply.purchase_request r ON r.id = l.request_id JOIN supply.receipt rc ON rc.order_id = l.order_id "
                       "JOIN finance.bill b ON b.id = rc.bill_id WHERE r.number = $1::bigint AND b.status = 'open' ORDER BY b.id", key)
    raise ana.Error("INVALID_PARAMETER", "esteira deve ser sales, field ou purchase")


def main(flow, key, tolerance_days=5):
    key = str(key).strip()
    bills = {b["id"]: b for b in document_bills(flow, key)}
    if not bills:
        return {"settled": 0, "open": 0, "waiting": None}
    sure, maybe = [], []
    for account in [r["code"] for r in ana.sql("SELECT code FROM finance.bank_account WHERE active ORDER BY code")]:
        # Only the lines that want this document's bills, then their whole candidate lists (spec 042, E-01): the same
        # decision as looking at every open line, without scanning the backlog.
        wanting = reconcile_rules.candidates(account, tolerance_days, None, sorted(bills))
        if not wanting:
            continue
        best = reconcile_rules.candidates(account, tolerance_days, sorted(wanting))
        claims = {}
        for line_id, cands in best.items():
            if len(cands) == 1:
                claims.setdefault(cands[0]["bill_id"], []).append(line_id)
        for line_id, cands in best.items():
            mine = [c for c in cands if c["bill_id"] in bills]
            if not mine:
                continue
            c = mine[0]
            certain = (len(cands) == 1 and Decimal(str(c["confidence"])) >= SURE and c["charge_status"] != "paid"
                       and len(claims.get(c["bill_id"], [])) == 1)
            (sure if certain else maybe).append((account, line_id, c))
    settled = 0
    if sure:
        lines = {r["id"]: r for r in ana.sql(
            "SELECT id, bank_account, posted_on, amount, description FROM finance.bank_statement_line "
            "WHERE id = ANY($1) AND status = 'open' FOR UPDATE", [lid for _, lid, _ in sure])}
        rows = {b["id"]: b for b in ana.sql("SELECT id, kind, amount FROM finance.bill WHERE id = ANY($1) AND status = 'open' FOR UPDATE",
                                            [c["bill_id"] for _, _, c in sure])}
        items = [{"line": lines[lid], "bills": [rows[c["bill_id"]]], "rule": c["rule"]}
                 for _, lid, c in sure if lid in lines and c["bill_id"] in rows]
        for rule in sorted({i["rule"] for i in items}):
            banking.settle_lines([i for i in items if i["rule"] == rule], rule, ana.context.user)
        charges = [c["charge_id"] for _, lid, c in sure if c["rule"] == "charge" and c["charge_id"]]
        if charges:
            ana.sql_exec("UPDATE finance.charge SET status = 'paid', paid_at = now() WHERE id = ANY($1) AND status = 'issued'", charges)
        settled = len(items)
    still = document_bills(flow, key)
    total = sum((Decimal(b["amount"]) for b in still), Decimal(0))
    if not still:
        waiting = None
    elif maybe:
        line = ana.sql_one("SELECT posted_on, amount, bank_account FROM finance.bank_statement_line WHERE id = $1", maybe[0][1])
        waiting = (f"há crédito no extrato que pode ser deste documento (R$ {abs(line['amount'])} em {line['posted_on']:%d/%m/%Y}, "
                   f"conta {line['bank_account']}): confirme na bancada de conciliação")
    else:
        waiting = f"aguardando o pagamento no extrato: {len(still)} título(s) em aberto, R$ {total}"
    if waiting:
        ana.actions([{"label": "Bancada de conciliação", "program": "finance.reconciliation",
                      "params": {"bank_account": maybe[0][0]} if maybe else {}, "open": True}], title="Próximo passo")
    return {"settled": settled, "open": len(still), "waiting": waiting,
            "suggestions": [{"line": lid, "bill": c["bill_id"], "rule": c["rule"]} for _, lid, c in maybe]}
