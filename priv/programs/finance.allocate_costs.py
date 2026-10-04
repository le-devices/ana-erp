# ana:description Rateio de custos do mês entre centros de custo (prévia ou execução)
# ana:exposed yes
# ana:role admin
"""RF-027-06. For each rule, the month's balance of the source center in the accounts of the
rule is moved to the targets by percentage (per account; cents remainder to the last target).
Preview by default; one allocation per rule and month (document RATEIO-<rule>-<AAAA-MM>)."""

import calendar
import datetime
from decimal import Decimal, ROUND_HALF_UP

PARAMS = {
    "month": {"type": "date", "required": True, "label": "mês (qualquer dia)"},
    "rule": {"type": "str", "label": "regra (vazio = todas)", "lookup": {"program": "finance.lookup", "params": {"kind": "rules"}}},
    "execute": {"type": "bool", "default": False, "label": "executar (desmarcado = só prévia)"},
}


def main(month, rule=None, execute=False):
    first = month.replace(day=1)
    last = month.replace(day=calendar.monthrange(month.year, month.month)[1])
    rules = ana.sql("SELECT * FROM finance.allocation_rule WHERE active AND ($1::text IS NULL OR code = upper($1)) "
                    "ORDER BY code", rule)
    if not rules:
        raise ana.Error("RULE_NOT_FOUND", "nenhuma regra de rateio ativa")
    out, done = [], []
    for r in rules:
        document = f"RATEIO-{r['code']}-{first:%Y-%m}"
        if ana.sql_value("SELECT count(*) FROM finance.journal_entry WHERE document = $1", document):
            if execute:
                raise ana.Error("ALREADY_ALLOCATED", f"o rateio {r['code']} de {first:%m/%Y} já foi feito ({document})")
            ana.log(f"{r['code']}: já rateado em {first:%m/%Y}", "warning")
            continue
        balances = ana.sql(
            "SELECT l.account, sum(l.debit - l.credit) AS balance FROM finance.journal_line l "
            "JOIN finance.journal_entry e ON e.id = l.entry_id "
            "WHERE l.cost_center = $1 AND l.account LIKE $2 || '%' AND e.entry_date BETWEEN $3 AND $4 "
            "GROUP BY l.account HAVING sum(l.debit - l.credit) <> 0 ORDER BY l.account",
            r["source"], r["account_prefix"], first, last)
        lines = []
        for b in balances:
            amount = Decimal(b["balance"])
            moved = Decimal(0)
            for i, t in enumerate(r["targets"]):
                part = amount - moved if i == len(r["targets"]) - 1 else \
                    (amount * Decimal(t["pct"]) / 100).quantize(Decimal("0.01"), ROUND_HALF_UP)
                moved += part
                lines.append([b["account"], t["cost_center"], part])
                out.append({"regra": r["code"], "conta": b["account"], "de": r["source"], "para": t["cost_center"],
                            "%": t["pct"], "valor": part})
            lines.append([b["account"], r["source"], -amount])
        if execute and lines:
            entry = ana.sql_value("INSERT INTO finance.journal_entry (entry_date, memo, document, created_by) "
                                  "VALUES ($1, $2, $3, $4) RETURNING id", last,
                                  f"Rateio {r['name']} — {first:%m/%Y}", document, ana.context.user)
            ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit, cost_center) "
                          "VALUES ($1, $2, $3, $4, $5)",
                          [[entry, acc, v if v > 0 else 0, -v if v < 0 else 0, cc] for acc, cc, v in lines if v != 0])
            done.append({"rule": r["code"], "entry": entry, "document": document})
    ana.table(out, title=("Rateio executado" if execute else "Prévia do rateio (nada foi gravado)") + f" — {first:%m/%Y}")
    if not execute and out:
        ana.actions([{"label": "Executar o rateio", "program": "finance.allocate_costs",
                      "params": {"month": first.isoformat(), "rule": rule, "execute": True},
                      "confirm": f"Gravar o rateio de {first:%m/%Y}?"}], title="Próximo passo")
    return {"month": first, "preview": not execute, "moves": out, "entries": done}
