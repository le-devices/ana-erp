# ana:description Lançamento contábil manual com centro de custo por linha
# ana:exposed yes
# ana:role developer
# ana:category Contabilidade/Lançamentos e fechamento
"""RF-027-04. lines: [{"account": "5.1.1", "debit": 100, "cost_center": "ADM"},
{"account": "1.1.1", "credit": 100}]. Double entry checked here (friendly) and at COMMIT
(database); cost center policies are enforced by the database for every program."""

from decimal import Decimal

PARAMS = {
    "memo": {"type": "str", "required": True, "label": "histórico"},
    "lines": {"type": "list", "required": True, "label": "linhas (débitos = créditos)", "columns": {
        "account": {"type": "str", "required": True, "label": "conta", "lookup": {"program": "finance.lookup", "params": {"kind": "accounts"}}},
        "debit": {"type": "decimal", "label": "débito"},
        "credit": {"type": "decimal", "label": "crédito"},
        "cost_center": {"type": "str", "label": "centro de custo", "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}}}},
    "entry_date": {"type": "date", "label": "data (vazio = hoje)"},
    "document": {"type": "str", "label": "documento"},
}


def main(memo, lines, entry_date=None, document=None):
    if not 2 <= len(lines) <= 500:
        raise ana.Error("INVALID_PARAMETER", "o lançamento precisa de 2 a 500 linhas")
    clean = []
    for n, l in enumerate(lines, start=1):
        d, c = Decimal(str(l.get("debit") or 0)), Decimal(str(l.get("credit") or 0))
        if (d > 0) == (c > 0) or d < 0 or c < 0:
            raise ana.Error("INVALID_LINE", f"linha {n}: informe débito ou crédito (positivo), não os dois")
        clean.append([str(l["account"]), d, c, (str(l["cost_center"]).upper() if l.get("cost_center") else None)])
    accounts = {r["code"]: r["postable"] for r in ana.sql(
        "SELECT code, postable FROM finance.account WHERE code = ANY($1::text[])", [x[0] for x in clean])}
    bad = sorted({x[0] for x in clean if not accounts.get(x[0])})
    if bad:
        raise ana.Error("ACCOUNT_NOT_POSTABLE", "contas inexistentes ou sintéticas: " + ", ".join(bad))
    if sum(x[1] for x in clean) != sum(x[2] for x in clean):
        raise ana.Error("UNBALANCED", f"débitos ({sum(x[1] for x in clean)}) diferentes dos créditos ({sum(x[2] for x in clean)})")
    if document and document.upper().startswith("RATEIO-"):
        raise ana.Error("INVALID_PARAMETER", "documentos RATEIO- são reservados ao rateio")
    entry = ana.sql_value("INSERT INTO finance.journal_entry (entry_date, memo, document, created_by, manual) "
                          "VALUES (COALESCE($1, current_date), $2, $3, $4, true) RETURNING id",
                          entry_date, memo.strip(), document, ana.context.user)
    try:
        ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit, cost_center) "
                      "VALUES ($1, $2, $3, $4, $5)", [[entry, *x] for x in clean])
    except ana.SqlError as e:
        for code in ("COST_CENTER_NOT_ALLOWED", "COST_CENTER_REQUIRED", "COST_CENTER_INACTIVE"):
            if code in e.message:
                raise ana.Error(code, e.message.split(": ", 1)[-1]) from None
        raise
    return {"entry": entry, "lines": len(clean)}
