# ana:description Rateio de custos do mês entre centros de custo (prévia ou execução)
# ana:exposed yes
# ana:role admin
# ana:category Contabilidade/Custos e orçamento
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
    rules = ana.sql("SELECT code, name, source, account_prefix, targets FROM finance.allocation_rule "
                    "WHERE active AND ($1::text IS NULL OR code = upper($1)) ORDER BY code", rule)
    if not rules:
        raise ana.Error("RULE_NOT_FOUND", "nenhuma regra de rateio ativa")
    documents = {r["code"]: f"RATEIO-{r['code']}-{first:%Y-%m}" for r in rules}
    already = {r["document"] for r in ana.sql("SELECT document FROM finance.journal_entry WHERE document = ANY($1)",
                                              list(documents.values()))}
    # Balances of every rule's source center in one query (set-based, RNF-027).
    balances = {}
    for b in ana.sql(
            "SELECT r.code, l.account, sum(l.debit - l.credit) AS balance "
            "FROM unnest($1::text[], $2::text[], $3::text[]) AS r(code, source, prefix) "
            "JOIN finance.journal_line l ON l.cost_center = r.source AND l.account LIKE r.prefix || '%' "
            "JOIN finance.journal_entry e ON e.id = l.entry_id AND e.entry_date BETWEEN $4 AND $5 "
            "GROUP BY r.code, l.account HAVING sum(l.debit - l.credit) <> 0 ORDER BY r.code, l.account",
            [r["code"] for r in rules], [r["source"] for r in rules], [r["account_prefix"] for r in rules], first, last):
        balances.setdefault(b["code"], []).append(b)
    out, done, pending = [], [], []
    for r in rules:
        document = documents[r["code"]]
        if document in already:
            if execute:
                raise ana.Error("ALREADY_ALLOCATED", f"o rateio {r['code']} de {first:%m/%Y} já foi feito ({document})")
            ana.log(f"{r['code']}: já rateado em {first:%m/%Y}", "warning")
            continue
        lines = []
        for b in balances.get(r["code"], []):
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
        if lines:
            pending.append((r, document, lines))
    if execute and pending:
        entries = {e["document"]: e["id"] for e in ana.sql(
            "INSERT INTO finance.journal_entry (entry_date, memo, document, created_by) "
            "SELECT $1, memo, document, $4 FROM unnest($2::text[], $3::text[]) AS x(memo, document) RETURNING id, document",
            last, [f"Rateio {r['name']} — {first:%m/%Y}" for r, _, _ in pending], [d for _, d, _ in pending],
            ana.context.user)}
        ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit, cost_center) "
                      "VALUES ($1, $2, $3, $4, $5)",
                      [[entries[d], acc, v if v > 0 else 0, -v if v < 0 else 0, cc]
                       for _, d, lines in pending for acc, cc, v in lines if v != 0])
        done = [{"rule": r["code"], "entry": entries[d], "document": d} for r, d, _ in pending]
    ana.table(out, title=("Rateio executado" if execute else "Prévia do rateio (nada foi gravado)") + f" — {first:%m/%Y}")
    if not execute and out:
        ana.actions([{"label": "Executar o rateio", "program": "finance.allocate_costs",
                      "params": {"month": first.isoformat(), "rule": rule, "execute": True},
                      "confirm": f"Gravar o rateio de {first:%m/%Y}?"}], title="Próximo passo")
    return {"month": first, "preview": not execute, "moves": out, "entries": done}
