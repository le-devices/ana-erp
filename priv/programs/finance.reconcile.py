# ana:description Conciliação bancária automática por regras (cobrança, documento, valor e data)
# ana:exposed yes
# ana:category Financeiro/Conciliação bancária
"""RF-017-07. Candidates for every open line in a few set-based queries:
1. charge id found in the line (confidence 1.0) — a charge already paid by the gateway is only
   linked to its entry (no second posting);
2. bill document in the line + same amount (0.95);
3. same amount + due date within ± tolerance (0.8 when it is the only one, 0.5 each otherwise).
Lines with a single candidate at or above the threshold are settled at once (in batch); the
rest stay for the manual workbench with their suggestions."""

from decimal import Decimal

from ana_lib.finance import banking, reconcile_rules, statement

PARAMS = {
    "bank_account": {"type": "str", "required": True, "label": "conta bancária",
                     "lookup": {"program": "finance.lookup", "params": {"kind": "bank_accounts"}}},
    "threshold": {"type": "decimal", "default": "0.9", "label": "confiança mínima para baixar sozinho (0 a 1)"},
    "tolerance_days": {"type": "int", "default": 3, "label": "tolerância de data (dias)"},
    "auto": {"type": "bool", "default": True, "label": "baixar automaticamente os casos certos"},
}


def main(bank_account, threshold="0.9", tolerance_days=3, auto=True):
    account = bank_account.strip().upper()
    banking.bank_ledger(account)
    threshold = Decimal(str(threshold))
    best = reconcile_rules.candidates(account, tolerance_days)
    # A bill wanted by two lines is never settled automatically.
    claims = {}
    for line_id, cands in best.items():
        if len(cands) == 1:
            claims.setdefault(cands[0]["bill_id"], []).append(line_id)
    sure = {line_id: cands[0] for line_id, cands in best.items()
            if len(cands) == 1 and Decimal(str(cands[0]["confidence"])) >= threshold
            and len(claims.get(cands[0]["bill_id"], [])) == 1}
    settled = linked = 0
    if auto and sure:
        lines = {r["id"]: r for r in ana.sql(
            "SELECT id, bank_account, posted_on, amount, description FROM finance.bank_statement_line "
            "WHERE id = ANY($1) AND status = 'open' FOR UPDATE", list(sure))}
        # Charges already paid in the gateway (spec 038): the line is their payout — D bank / C gateway receivable.
        paid = [(lid, c) for lid, c in sure.items() if c["rule"] == "charge" and c["charge_status"] == "paid" and lid in lines]
        gateway = ana.sql_value("SELECT finance.account_for('gateway_receivable')")
        for lid, c in paid:
            ch = ana.sql_one("SELECT id, net, payout_line_id, entry_id FROM finance.charge WHERE id = $1 FOR UPDATE", c["charge_id"])
            if ch["net"] is not None and ch["payout_line_id"] is None:
                statement.post_line(lines[lid], gateway, None, f"Repasse do gateway — {lines[lid]['description'] or ''}", "gateway",
                                    ana.context.user)
                ana.sql_exec("UPDATE finance.charge SET payout_line_id = $2 WHERE id = $1", ch["id"], lid)
            else:      # paid before spec 038 (posted straight to the bank): link only, no second posting
                ana.sql_exec("UPDATE finance.bank_statement_line SET status = 'matched', entry_id = $2, matched_by = $3, "
                             "matched_at = now(), rule = 'charge' WHERE id = $1", lid, ch["entry_id"], ana.context.user)
            linked += 1
        to_settle = [(lid, c) for lid, c in sure.items() if lid in lines and not (c["rule"] == "charge" and c["charge_status"] == "paid")]
        bills = {b["id"]: b for b in ana.sql("SELECT id, kind, amount FROM finance.bill WHERE id = ANY($1) AND status = 'open' "
                                             "FOR UPDATE", [c["bill_id"] for _, c in to_settle])}
        items = [{"line": lines[lid], "bills": [bills[c["bill_id"]]], "rule": c["rule"]}
                 for lid, c in to_settle if c["bill_id"] in bills]
        for rule in sorted({i["rule"] for i in items}):
            banking.settle_lines([i for i in items if i["rule"] == rule], rule, ana.context.user)
        charge_ids = [c["charge_id"] for lid, c in to_settle if c["rule"] == "charge" and c["bill_id"] in bills]
        if charge_ids:
            ana.sql_exec("UPDATE finance.charge SET status = 'paid', paid_at = now() WHERE id = ANY($1)", charge_ids)
        settled = len(items)
    # Spec 038 (RF-038-06, 07): lines without a bill — posting rules, own transfers and gateway payouts.
    by_rule = transfers = payouts = 0
    if auto:
        by_rule = statement.apply_rules(account, ana.context.user, set(best))
        transfers = statement.own_transfers(ana.context.user)
        payouts = statement.gateway_payouts(account, ana.context.user)
    pending = [lid for lid in best if lid not in sure or not auto]
    open_count = ana.sql_value("SELECT count(*) FROM finance.bank_statement_line WHERE bank_account = $1 AND status = 'open'",
                               account)
    ana.metrics([{"label": "Baixadas agora", "value": settled, "status": "ok"},
                 {"label": "Repasses do gateway", "value": linked + payouts},
                 {"label": "Pelas regras (tarifas, IOF…)", "value": by_rule},
                 {"label": "Transferências entre contas", "value": transfers},
                 {"label": "Com sugestão para conferir", "value": len(pending), "status": "warn" if pending else "ok"},
                 {"label": "Abertas no extrato", "value": open_count}])
    ana.actions([{"label": "Abrir a conciliação manual", "program": "finance.reconciliation",
                  "params": {"bank_account": account}, "open": True, "style": "primary"}], title="Próximo passo")
    return {"settled": settled, "linked": linked, "payouts": payouts, "rules": by_rule, "transfers": transfers,
            "suggestions": {str(lid): [{"bill": c["bill_id"], "rule": c["rule"], "confidence": c["confidence"]}
                                       for c in best[lid]] for lid in pending}}
