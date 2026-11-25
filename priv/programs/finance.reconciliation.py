# ana:description Bancada de conciliação: linhas do extrato em aberto com as sugestões de títulos
# ana:command conciliar
# ana:category Financeiro/Conciliação bancária
"""H3: each open line shows its suggestions (best rule first) with the action on the row;
lines without a suggestion can be matched by bill number or ignored."""

from ana_lib.finance import reconcile_rules

PARAMS = {
    "bank_account": {"type": "str", "default": "CAIXA", "label": "conta bancária",
                     "lookup": {"program": "finance.lookup", "params": {"kind": "bank_accounts"}}},
    "tolerance_days": {"type": "int", "default": 3, "label": "tolerância de data (dias)"},
}
RULES = {"charge": "cobrança", "document": "documento + valor", "amount_date": "valor + data"}


def main(bank_account="CAIXA", tolerance_days=3):
    account = bank_account.strip().upper()
    counts = ana.sql_one(
        "SELECT count(*) FILTER (WHERE status = 'open') AS open, count(*) FILTER (WHERE status = 'matched') AS matched, "
        "  COALESCE(sum(amount) FILTER (WHERE status = 'open' AND amount > 0), 0) AS open_in, "
        "  COALESCE(-sum(amount) FILTER (WHERE status = 'open' AND amount < 0), 0) AS open_out "
        "FROM finance.bank_statement_line WHERE bank_account = $1", account)
    ana.metrics([{"label": "Em aberto", "value": counts["open"], "status": "warn" if counts["open"] else "ok"},
                 {"label": "Conciliadas", "value": counts["matched"]},
                 {"label": "Entradas a conciliar", "value": f"R$ {counts['open_in']:.2f}"},
                 {"label": "Saídas a conciliar", "value": f"R$ {counts['open_out']:.2f}"}])
    lines = ana.sql("SELECT id, posted_on, amount, description, document FROM finance.bank_statement_line "
                    "WHERE bank_account = $1 AND status = 'open' ORDER BY posted_on, id LIMIT 300", account)
    best = reconcile_rules.candidates(account, tolerance_days)
    bills = {b["id"]: b for b in ana.sql(
        "SELECT b.id, b.document, b.due_date, b.amount, p.name FROM finance.bill b JOIN base.party p ON p.id = b.party_id "
        "WHERE b.id = ANY($1)", sorted({c["bill_id"] for cs in best.values() for c in cs}))}
    rows = []
    for l in lines:
        cands = best.get(l["id"], [])
        sug = "; ".join(f"{bills[c['bill_id']]['document']} — {bills[c['bill_id']]['name']} ({RULES[c['rule']]}, "
                        f"{int(c['confidence'] * 100)}%)" for c in cands if c["bill_id"] in bills)
        actions = [{"label": f"Baixar {bills[c['bill_id']]['document']}", "program": "finance.match_statement_line",
                    "params": {"line": l["id"], "bills": [c["bill_id"]], "accept_difference": True}, "style": "primary"}
                   for c in cands[:3] if c["bill_id"] in bills]
        actions.append({"label": "Outros títulos", "program": "finance.match_statement_line", "params": {"line": l["id"]},
                        "ask": {"bills": {"type": "list", "label": "números dos títulos", "required": True},
                                "accept_difference": {"type": "bool", "label": "lançar diferença em juros/tarifas"}}})
        actions.append({"label": "Ignorar", "program": "finance.match_statement_line", "params": {"line": l["id"], "ignore": True},
                        "ask": {"reason": {"type": "str", "label": "motivo", "required": True}}})
        rows.append({"linha": l["id"], "data": l["posted_on"], "valor": l["amount"], "histórico": l["description"],
                     "documento": l["document"], "sugestões": sug or "—", "_actions": actions})
    ana.table(rows, title=f"Extrato em aberto — {account}", empty="Nenhuma linha de extrato em aberto nesta conta.",
              empty_action={"label": "Buscar extratos", "program": "finance.fetch_statements"})
    ana.actions([{"label": "Conciliar automaticamente", "program": "finance.reconcile", "params": {"bank_account": account}},
                 {"label": "Importar extrato", "program": "finance.import_statement", "params": {"bank_account": account},
                  "open": True}], title="Outras tarefas")
    return {"open": counts["open"], "lines": len(rows)}
