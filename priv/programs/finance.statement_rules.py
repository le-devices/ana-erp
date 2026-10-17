# ana:description Regras do extrato: linhas sem título (tarifas, IOF, rendimentos…) lançadas sozinhas na conta certa
# ana:exposed yes
# ana:role admin
"""Spec 038 (RF-038-06, CA-038-08). The text is looked for in the line's description and document (case does
not matter). Without parameters: lists the rules; with pattern and account: creates one; remove: deletes."""

PARAMS = {"pattern": {"type": "str", "label": "texto no histórico (ex.: TARIFA)"},
          "account": {"type": "str", "label": "conta contábil", "lookup": {"program": "finance.lookup", "params": {"kind": "accounts"}}},
          "direction": {"type": "str", "default": "any", "label": "sentido", "choices": [["any", "Entradas e saídas"], ["in", "Entradas"], ["out", "Saídas"]]},
          "bank_account": {"type": "str", "label": "conta bancária (vazio = todas)", "lookup": {"program": "finance.lookup", "params": {"kind": "bank_accounts"}}},
          "cost_center": {"type": "str", "label": "centro de custo", "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}},
          "memo": {"type": "str", "label": "histórico do lançamento"},
          "priority": {"type": "int", "default": 100, "label": "prioridade (menor vale primeiro)"},
          "remove": {"type": "int", "label": "apagar a regra (id)"}}


def main(pattern=None, account=None, direction="any", bank_account=None, cost_center=None, memo=None, priority=100, remove=None):
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
