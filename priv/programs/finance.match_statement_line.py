# ana:description Concilia manualmente uma linha do extrato com um ou mais títulos (ou ignora a linha)
# ana:exposed yes
"""RF-017-07. One line ↔ N bills of the same direction. A difference (interest received or
fees) needs accept_difference. ignore marks lines that are not bills (transfers, investments)."""

from decimal import Decimal

from ana_lib.finance import banking

PARAMS = {
    "line": {"type": "int", "required": True, "label": "linha do extrato"},
    "bills": {"type": "list", "label": "títulos"},
    "accept_difference": {"type": "bool", "default": False, "label": "lançar a diferença em juros/tarifas"},
    "ignore": {"type": "bool", "default": False, "label": "ignorar a linha (não é título)"},
    "reason": {"type": "str", "label": "motivo (ao ignorar)"},
}


def main(line, bills=None, accept_difference=False, ignore=False, reason=None):
    l = ana.sql_one("SELECT id, bank_account, posted_on, amount, description, status FROM finance.bank_statement_line "
                    "WHERE id = $1 FOR UPDATE", line)
    if not l:
        raise ana.Error("LINE_NOT_FOUND", f"linha {line} não encontrada")
    if l["status"] != "open":
        raise ana.Error("LINE_NOT_OPEN", f"linha {line} já está {l['status']}")
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
        raise ana.Error("DIFFERENCE", f"a linha difere dos títulos em R$ {difference}; confirme para lançar em "
                        + ("juros recebidos" if difference > 0 else "tarifas"), {"difference": difference})
    banking.settle_lines([{"line": l, "bills": rows, "difference": difference}], "manual", ana.context.user)
    return {"line": line, "bills": ids, "difference": difference}
