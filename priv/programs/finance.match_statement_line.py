# ana:description Concilia manualmente uma linha do extrato com um ou mais títulos (ou ignora a linha)
# ana:exposed yes
"""RF-017-07. One line ↔ N bills of the same direction. A difference (interest received or
fees) needs accept_difference. ignore marks lines that are not bills (transfers, investments)."""

from decimal import Decimal

from ana_lib.finance import banking

PARAMS = {
    "line": {"type": "int", "required": True, "label": "linha do extrato"},
    "bills": {"type": "list", "label": "títulos"},
    "accept_difference": {"type": "bool", "default": False, "label": "aceitar a diferença (tolerância: juros/tarifa; acima: residual ou crédito)"},
    "post_to": {"type": "str", "label": "lançar a linha nesta conta (sem título: tarifa, IOF, rendimento…)",
                "lookup": {"program": "finance.lookup", "params": {"kind": "accounts"}}},
    "cost_center": {"type": "str", "label": "centro de custo do lançamento", "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}},
    "ignore": {"type": "bool", "default": False, "label": "ignorar a linha (não é título)"},
    "reason": {"type": "str", "label": "motivo (ao ignorar)"},
}


def main(line, bills=None, accept_difference=False, ignore=False, reason=None, post_to=None, cost_center=None):
    l = ana.sql_one("SELECT id, bank_account, posted_on, amount, description, status FROM finance.bank_statement_line "
                    "WHERE id = $1 FOR UPDATE", line)
    if not l:
        raise ana.Error("LINE_NOT_FOUND", f"linha {line} não encontrada")
    if l["status"] != "open":
        raise ana.Error("LINE_NOT_OPEN", f"linha {line} já está {l['status']}")
    if post_to:
        # Spec 038 (L-14): a line without a bill (fee, IOF, yield, investment) gets its entry — never just ignored.
        acc = ana.sql_one("SELECT code FROM finance.account WHERE code = $1 AND postable", post_to)
        if not acc:
            raise ana.Error("INVALID_PARAMETER", f"conta {post_to} inexistente ou não lançável")
        from ana_lib.finance import statement
        statement.post_line(l, post_to, cost_center, reason or "lançamento do extrato", "manual", ana.context.user)
        return {"line": line, "status": "matched", "account": post_to}
    if ignore:
        if not reason:
            raise ana.Error("INVALID_PARAMETER", "informe o motivo")
        ana.sql_exec("UPDATE finance.bank_statement_line SET status = 'ignored', matched_by = $2, matched_at = now(), "
                     "description = description || ' [ignorada: ' || $3 || ']' WHERE id = $1", line, ana.context.user, reason)
        return {"line": line, "status": "ignored"}
    ids = sorted({int(b) for b in bills or []})
    if not ids:
        raise ana.Error("INVALID_PARAMETER", "escolha ao menos um título")
    kind = "receivable" if l["amount"] > 0 else "payable"
    rows = ana.sql("SELECT id, kind, amount, status FROM finance.bill WHERE id = ANY($1) ORDER BY id FOR UPDATE", ids)
    wrong = [r["id"] for r in rows if r["status"] != "open" or r["kind"] != kind]
    if len(rows) != len(ids) or wrong:
        raise ana.Error("INVALID_BILLS", "títulos inexistentes, já baixados ou do sentido errado: "
                        + ", ".join(map(str, wrong or sorted(set(ids) - {r['id'] for r in rows}))))
    difference = abs(l["amount"]) - sum((r["amount"] for r in rows), Decimal(0))
    if difference and not accept_difference:
        tol = banking.policy()["tolerance"]
        what = ("juros recebidos" if difference > 0 else "tarifas") if abs(difference) <= tol else \
            ("crédito do parceiro" if difference > 0 else "título residual com o que falta")
        raise ana.Error("DIFFERENCE", f"a linha difere dos títulos em R$ {difference}; confirme para lançar em {what}",
                        {"difference": difference, "tolerance": tol})
    banking.settle_lines([{"line": l, "bills": rows}], "manual", ana.context.user)
    return {"line": line, "bills": ids, "difference": difference, "details": banking.settle_lines.last_report}
