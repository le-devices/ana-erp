# ana:description Regras do extrato: linhas sem título (tarifas, IOF, rendimentos…) lançadas sozinhas na conta certa
# ana:exposed yes
# ana:role admin
# ana:category Financeiro/Conciliação bancária
"""Spec 038 (RF-038-06, CA-038-08). The text is looked for in the line's description and document (case does
not matter). Without parameters: lists the rules; with pattern and account: creates one; remove: deletes.
Spec 020 (RF-020-13, CA-020-08): "Simular" shows, without saving, the open lines the rule would take."""

PARAMS = {"pattern": {"type": "str", "label": "texto no histórico (ex.: TARIFA)"},
          "account": {"type": "str", "label": "conta contábil", "lookup": {"program": "finance.lookup", "params": {"kind": "accounts"}}},
          "direction": {"type": "str", "default": "any", "label": "sentido", "choices": [["any", "Entradas e saídas"], ["in", "Entradas"], ["out", "Saídas"]]},
          "bank_account": {"type": "str", "label": "conta bancária (vazio = todas)", "lookup": {"program": "finance.lookup", "params": {"kind": "bank_accounts"}}},
          "cost_center": {"type": "str", "label": "centro de custo", "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}},
          "memo": {"type": "str", "label": "histórico do lançamento"},
          "priority": {"type": "int", "default": 100, "label": "prioridade (menor vale primeiro)"},
          "remove": {"type": "int", "label": "apagar a regra (id)"},
          "simulate": {"type": "bool", "simulate": True, "label": "simular (não grava)"}}


def main(pattern=None, account=None, direction="any", bank_account=None, cost_center=None, memo=None, priority=100, remove=None,
         simulate=False):
    if simulate:
        return simulation(pattern, direction, bank_account)
    if remove:
        ana.sql_exec("DELETE FROM finance.statement_rule WHERE id = $1", remove)
    elif pattern or account:
        if not (pattern and len(pattern.strip()) >= 2 and account):
            raise ana.Error("INVALID_PARAMETER", "informe o texto (2+ letras) e a conta")
        if not ana.sql_value("SELECT count(*) FROM finance.account WHERE code = $1 AND postable", account):
            raise ana.Error("INVALID_PARAMETER", f"conta {account} inexistente ou não lançável")
        ana.sql_exec("INSERT INTO finance.statement_rule (bank_account, pattern, direction, account, cost_center, memo, priority, created_by) "
                     "VALUES ($1, $2, $3, $4, $5, COALESCE($6, ''), $7, $8)", (bank_account or "").upper() or None, pattern.strip(),
                     direction, account, cost_center or None, memo, priority, ana.context.user)
    rows = ana.sql("SELECT r.id, r.pattern, r.direction, r.account, a.description AS conta, r.bank_account, r.cost_center, r.memo, r.priority "
                   "FROM finance.statement_rule r JOIN finance.account a ON a.code = r.account WHERE r.active ORDER BY r.priority, r.id")
    ana.table([{"id": r["id"], "texto": r["pattern"], "sentido": {"any": "ambos", "in": "entradas", "out": "saídas"}[r["direction"]],
                "conta": f"{r['account']} {r['conta']}", "banco": r["bank_account"] or "todos", "centro": r["cost_center"] or "",
                "_actions": [{"label": "Apagar", "program": "finance.statement_rules", "params": {"remove": r["id"]}}]} for r in rows],
              title="Regras do extrato")
    return {"rules": rows}


def simulation(pattern, direction, bank_account):
    """Open statement lines the rule would post (same test as finance.statement.apply_rules), nothing saved."""
    if not (pattern and len(pattern.strip()) >= 2):
        raise ana.Error("INVALID_PARAMETER", "informe o texto (2+ letras) para simular")
    # ana:lint-ok leading_wildcard — open lines only (the reconciliation's working set)
    lines = ana.sql("SELECT l.id, l.posted_on, l.bank_account, l.description, l.document, l.amount FROM finance.bank_statement_line l "
                    "WHERE l.status = 'open' AND ($1::text IS NULL OR l.bank_account = $1) "
                    "AND strpos(lower(COALESCE(l.description, '') || ' ' || COALESCE(l.document, '')), lower($2)) > 0 "
                    "AND ($3 = 'any' OR ($3 = 'in') = (l.amount > 0)) ORDER BY l.posted_on, l.id LIMIT 1000",
                    (bank_account or "").upper() or None, pattern.strip(), direction)
    total = sum(l["amount"] for l in lines)
    ana.table([{"data": l["posted_on"], "conta bancária": l["bank_account"], "histórico": l["description"], "documento": l["document"] or "",
                "valor": l["amount"], "_open": {"program": "finance.reconciliation", "params": {"bank_account": l["bank_account"]}}}
               for l in lines], title="Linhas abertas que a regra pegaria")
    return {"simulated": True, "lines": len(lines), "total": total}
