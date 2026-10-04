# ana:description Linhas de base do projeto e comparação entre elas
"""RF-021-06. Without `a`/`b`, compares the two most recent baselines."""

from ana_lib.projects import access
from ana_lib.projects import views as V

PARAMS = {
    "project": {"type": "str", "required": True},
    "a": {"type": "int", "label": "linha de base A"},
    "b": {"type": "int", "label": "linha de base B"},
}


def main(project, a=None, b=None):
    p = access.project(project)
    V.require_view(p)
    all_ = ana.sql("SELECT b.*, c.number AS change_number FROM projects.baseline b "
                   "LEFT JOIN projects.scope_change c ON c.id = b.change_id "
                   "WHERE b.project_id = $1 ORDER BY b.number", p["id"])
    manage = access.can_manage(p)
    if not manage:          # projected cost/profit are confidential (RNF-021-02)
        for x in all_:
            for k in ("projected_cost", "projected_profit", "total_value", "low_margin_justification"):
                x[k] = None
    ana.table([{"nº": x["number"], "motivo": x["reason"], "mudança": x["change_number"] or "",
                "horas": x["total_hours"], "término": V.fmt(x["finish_date"]),
                **({"lucro projetado": V.fmt(x["projected_profit"]),
                    "justificativa de margem": x["low_margin_justification"] or ""} if manage else {}),
                "por": x["created_by"], "em": V.fmt(x["created_at"].date())} for x in all_], title="Linhas de base")
    if len(all_) < 2 and not (a and b):
        return {"baselines": all_}
    a = a or all_[-2]["number"]
    b = b or all_[-1]["number"]
    rows = ana.sql(
        "WITH x AS (SELECT i.* FROM projects.baseline_item i JOIN projects.baseline bl ON bl.id = i.baseline_id "
        "           WHERE bl.project_id = $1 AND bl.number = $2), "
        "     y AS (SELECT i.* FROM projects.baseline_item i JOIN projects.baseline bl ON bl.id = i.baseline_id "
        "           WHERE bl.project_id = $1 AND bl.number = $3) "
        "SELECT COALESCE(y.code, x.code) AS code, COALESCE(y.name, x.name) AS name, "
        "  x.planned_hours AS hours_a, y.planned_hours AS hours_b, x.planned_finish AS finish_a, "
        "  y.planned_finish AS finish_b FROM x FULL JOIN y ON y.code = x.code "
        "WHERE x.code IS NULL OR y.code IS NULL OR x.planned_hours <> y.planned_hours "
        "   OR x.planned_finish IS DISTINCT FROM y.planned_finish ORDER BY 1", p["id"], a, b)
    ana.table([{"código": r["code"], "item": r["name"], f"horas LB{a}": r["hours_a"] if r["hours_a"] is not None else "—",
                f"horas LB{b}": r["hours_b"] if r["hours_b"] is not None else "—",
                f"término LB{a}": V.fmt(r["finish_a"]), f"término LB{b}": V.fmt(r["finish_b"])} for r in rows],
              title=f"Diferenças entre as linhas de base {a} e {b}")
    return {"baselines": all_, "a": a, "b": b, "differences": rows}
