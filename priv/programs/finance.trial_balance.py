# ana:description Balancete por conta no período
# ana:command trialbalance
from ana_lib.util.format import money

PARAMS = {
    "start": {"type": "date", "label": "de"},
    "end": {"type": "date", "label": "até"},
    "cost_center": {"type": "str", "label": "centro de custo (com os filhos)",
                    "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}},
}


def main(start=None, end=None, cost_center=None):
    rows = ana.sql(
        "SELECT a.code, a.description, a.nature, "
        "       COALESCE(sum(l.debit), 0) AS debits, COALESCE(sum(l.credit), 0) AS credits "
        "FROM finance.account a "
        "LEFT JOIN finance.journal_line l ON l.account = a.code "
        "     AND EXISTS (SELECT 1 FROM finance.journal_entry e WHERE e.id = l.entry_id "
        "                 AND ($1::date IS NULL OR e.entry_date >= $1) AND ($2::date IS NULL OR e.entry_date <= $2)) "
        "     AND ($3::text IS NULL OR l.cost_center IN (WITH RECURSIVE d AS ("
        "          SELECT code FROM finance.cost_center WHERE code = upper($3) "
        "          UNION ALL SELECT c.code FROM finance.cost_center c JOIN d ON c.parent_code = d.code) SELECT code FROM d)) "
        "WHERE a.postable "
        "GROUP BY a.code, a.description, a.nature ORDER BY a.code", start, end, cost_center)
    for r in rows:
        r["balance"] = r["debits"] - r["credits"]
    ana.table([{"conta": r["code"], "descrição": r["description"],
                "débitos": money(r["debits"]), "créditos": money(r["credits"]),
                "saldo": money(r["balance"])} for r in rows],
              title="Balancete" + (f" — centro {cost_center.upper()} (com os filhos)" if cost_center else ""))
    total_d = sum(r["debits"] for r in rows)
    total_c = sum(r["credits"] for r in rows)
    return {"debits": total_d, "credits": total_c, "balanced": total_d == total_c}
