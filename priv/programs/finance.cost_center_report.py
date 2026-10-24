# ana:description Resultado gerencial por centro de custo: receitas, despesas, orçado × realizado
# ana:command centros
# ana:category Contabilidade/Custos e orçamento
"""RF-027-05/07. Children roll up into their parents. Revenue = credits − debits of revenue
accounts; expense = debits − credits of expense accounts."""

import datetime
from decimal import Decimal

PARAMS = {
    "start": {"type": "date", "label": "de (vazio = início do ano)"},
    "end": {"type": "date", "label": "até (vazio = hoje)"},
    "cost_center": {"type": "str", "label": "só este centro (com os filhos)",
                    "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}},
}
ZERO = Decimal(0)


def main(start=None, end=None, cost_center=None):
    today = datetime.date.today()
    start = start or today.replace(month=1, day=1)
    end = end or today
    # ana:lint-ok unbounded_select — cost centers: small table, the whole hierarchy is needed for the roll-up
    centers = {r["code"]: r for r in ana.sql("SELECT code, name, parent_code, kind FROM finance.cost_center")}
    actual = ana.sql(
        "SELECT l.cost_center, a.nature, to_char(date_trunc('month', e.entry_date), 'YYYY-MM-01') AS month, "
        "  sum(CASE WHEN a.nature = 'revenue' THEN l.credit - l.debit ELSE l.debit - l.credit END) AS amount "
        "FROM finance.journal_line l JOIN finance.journal_entry e ON e.id = l.entry_id "
        "JOIN finance.account a ON a.code = l.account "
        "WHERE l.cost_center IS NOT NULL AND a.nature IN ('revenue', 'expense') AND e.entry_date BETWEEN $1 AND $2 "
        "GROUP BY 1, 2, 3", start, end)
    budget = ana.sql(
        "SELECT b.cost_center, a.nature, sum(b.amount) AS amount FROM finance.cost_center_budget b "
        "JOIN finance.account a ON a.code = b.account WHERE b.month BETWEEN date_trunc('month', $1::date) AND $2 "
        "GROUP BY 1, 2", start, end)

    def ancestors(code):
        seen = []
        while code and code not in seen:
            seen.append(code)
            code = centers.get(code, {}).get("parent_code")
        return seen

    totals = {c: {"revenue": ZERO, "expense": ZERO, "b_revenue": ZERO, "b_expense": ZERO} for c in centers}
    monthly = {}
    for r in actual:
        for c in ancestors(r["cost_center"]):          # roll up into every ancestor
            totals[c][r["nature"]] += r["amount"]
        top = ancestors(r["cost_center"])[-1]
        key = (top, r["month"])
        monthly[key] = monthly.get(key, ZERO) + (r["amount"] if r["nature"] == "revenue" else -r["amount"])
    for r in budget:
        for c in ancestors(r["cost_center"]):
            totals[c]["b_" + r["nature"]] += r["amount"]

    roots = [c for c, v in centers.items() if not v["parent_code"]] if not cost_center else [cost_center.upper()]
    rows, chart_x, chart_rev, chart_exp = [], [], [], []

    def walk(code, depth):
        t = totals.get(code)
        if t is None:
            return
        result = t["revenue"] - t["expense"]
        b_result = t["b_revenue"] - t["b_expense"]
        rows.append({"centro": "   " * depth + f"{code} — {centers[code]['name']}", "receitas": t["revenue"],
                     "despesas": t["expense"], "resultado": result,
                     "margem %": round(result / t["revenue"] * 100, 1) if t["revenue"] else None,
                     "resultado orçado": b_result if (t["b_revenue"] or t["b_expense"]) else None,
                     "variação": (result - b_result) if (t["b_revenue"] or t["b_expense"]) else None})
        for child in sorted(c for c, v in centers.items() if v["parent_code"] == code):
            walk(child, depth + 1)

    for root in sorted(roots):
        walk(root, 0)
        if root in totals:
            chart_x.append(root)
            chart_rev.append(totals[root]["revenue"])
            chart_exp.append(totals[root]["expense"])
    if chart_x:
        ana.chart(type="column", title="Receitas × despesas por centro", subtitle=f"{start:%d/%m/%Y} a {end:%d/%m/%Y}",
                  format="money", x=chart_x, series=[{"name": "Receitas", "values": chart_rev},
                                                     {"name": "Despesas", "values": chart_exp}])
        months = sorted({m for _, m in monthly})
        tops = [c for c in chart_x if any((c, m) in monthly for m in months)][:8]
        if len(months) >= 2 and tops:
            ana.chart(type="line", title="Resultado mensal por centro", format="money", x=months,
                      series=[{"name": c, "values": [monthly.get((c, m), 0) for m in months]} for c in tops])
    ana.table(rows, title="Resultado gerencial por centro de custo (os pais somam os filhos)")
    return {"start": start, "end": end, "centers": rows}
