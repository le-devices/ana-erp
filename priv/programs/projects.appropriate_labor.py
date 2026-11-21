# ana:description Apropria o custo das horas aprovadas do mês aos projetos (prévia ou execução)
# ana:exposed yes
# ana:role admin
# ana:category Projetos/Faturamento e custos
"""Spec 038 (RF-038-11, L-10). Approved (or invoiced) hours of the month not yet appropriated become, per
project, one entry D project costs (project cost center) / C labor absorbed, at the hourly cost frozen
on approval. Each entry points to its hours (time_entry.labor_entry_id): running twice never doubles.
Preview by default; the monthly routine runs it with execute."""

import calendar
from decimal import Decimal

PARAMS = {
    "month": {"type": "date", "required": True, "label": "mês (qualquer dia)"},
    "execute": {"type": "bool", "default": False, "label": "executar (desmarcado = só prévia)"},
}

CENT = Decimal("0.01")


def main(month, execute=False):
    first = month.replace(day=1)
    last = month.replace(day=calendar.monthrange(month.year, month.month)[1])
    rows = ana.sql(
        "SELECT p.id, p.code, p.cost_center, count(*) AS entries, sum(t.hours) AS hours, "
        "  sum(round(t.hours * t.hourly_cost, 2)) AS cost, array_agg(t.id ORDER BY t.id) AS ids "
        "FROM projects.time_entry t JOIN projects.project p ON p.id = t.project_id "
        "WHERE t.entry_date BETWEEN $1 AND $2 AND t.status IN ('approved', 'invoiced') AND t.labor_entry_id IS NULL "
        "  AND t.hourly_cost > 0 "
        "GROUP BY p.id, p.code, p.cost_center ORDER BY p.code", first, last)
    out = [{"project": r["code"], "cost_center": r["cost_center"], "entries": r["entries"], "hours": r["hours"],
            "cost": Decimal(r["cost"]).quantize(CENT)} for r in rows]
    if not execute:
        return {"month": f"{first:%Y-%m}", "preview": True, "projects": out,
                "total": sum((o["cost"] for o in out), Decimal(0))}
    done = []
    for r, o in zip(rows, out):
        if o["cost"] <= 0:
            continue
        # Lock the hours: a concurrent run (or an invoice) of the same entries makes this one wait, then skip them.
        ids = [x["id"] for x in ana.sql("SELECT id FROM projects.time_entry WHERE id = ANY($1) AND labor_entry_id IS NULL "
                                        "ORDER BY id FOR UPDATE", r["ids"])]
        if len(ids) != len(r["ids"]):
            raise ana.Error("CONCURRENT_RUN", "outra apropriação do mesmo período está em andamento; tente de novo")
        ana.sql("SELECT set_config('ana.cost_center', $1, true)", r["cost_center"] or "")
        entry = ana.sql_value("INSERT INTO finance.journal_entry (entry_date, memo, document, created_by) "
                              "VALUES ($1, $2, $3, $4) RETURNING id",
                              last, f"Apropriação de mão de obra {first:%m/%Y} — projeto {r['code']}",
                              f"MO-{r['code']}-{first:%Y-%m}", ana.context.user)
        ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit) VALUES ($1, finance.account_for($2), $3, $4)",
                      [[entry, "project_costs", o["cost"], 0], [entry, "labor_absorbed", 0, o["cost"]]])
        ana.sql_exec("UPDATE projects.time_entry SET labor_entry_id = $2 WHERE id = ANY($1)", ids, entry)
        done.append({**o, "entry": entry})
    return {"month": f"{first:%Y-%m}", "preview": False, "projects": done,
            "total": sum((o["cost"] for o in done), Decimal(0))}
