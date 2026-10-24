# ana:description Painel de projetos: orçado × realizado, custo, faturado e margem
# ana:command projects
# ana:category Projetos/Acompanhamento
"""RF-008-14. Cost and margin appear only for projects the user manages
(or for admins) — RNF-008-02."""

from decimal import Decimal

from ana_lib.projects import access
from ana_lib.util.format import money

PARAMS = {
    "project": {"type": "str", "label": "projeto", "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
}


def main(project=None):
    rows = ana.sql(
        "WITH h AS (SELECT project_id, "
        "    sum(hours) FILTER (WHERE status <> 'rejected') AS hours_logged, "
        "    sum(hours) FILTER (WHERE status IN ('approved', 'invoiced')) AS hours_approved, "
        "    sum(hours * hourly_cost) FILTER (WHERE status IN ('approved', 'invoiced')) AS hours_cost, "
        "    sum(round(hours * hourly_rate, 2)) FILTER (WHERE status = 'approved' AND billable) AS hours_to_invoice "
        "  FROM projects.time_entry GROUP BY project_id), "
        " d AS (SELECT project_id, sum(quantity * unit_cost) AS expense_cost, "
        "    sum(round(quantity * unit_cost * (1 + markup_pct / 100), 2)) "
        "      FILTER (WHERE rebillable AND status = 'posted') AS expenses_to_invoice "
        "  FROM projects.expense GROUP BY project_id), "
        " m AS (SELECT project_id, sum(amount) FILTER (WHERE status = 'completed') AS milestones_to_invoice "
        "  FROM projects.milestone GROUP BY project_id), "
        " f AS (SELECT project_id, sum(total) AS invoiced FROM projects.invoice "
        "  WHERE status = 'issued' GROUP BY project_id), "
        " t AS (SELECT project_id, sum(planned_hours) AS planned_hours FROM projects.task GROUP BY project_id) "
        "SELECT p.code, p.name, p.status, p.manager, c.name AS customer, p.budget_hours, p.budget_amount, "
        "  COALESCE(t.planned_hours, 0) AS planned_hours, COALESCE(h.hours_logged, 0) AS hours_logged, "
        "  COALESCE(h.hours_approved, 0) AS hours_approved, "
        "  round(COALESCE(h.hours_cost, 0) + COALESCE(d.expense_cost, 0), 2) AS cost, "
        "  COALESCE(f.invoiced, 0) AS invoiced, "
        "  COALESCE(h.hours_to_invoice, 0) + COALESCE(d.expenses_to_invoice, 0) "
        "    + COALESCE(m.milestones_to_invoice, 0) AS to_invoice "
        "FROM projects.project p JOIN base.party c ON c.id = p.customer_id "
        "LEFT JOIN h ON h.project_id = p.id LEFT JOIN d ON d.project_id = p.id "
        "LEFT JOIN m ON m.project_id = p.id LEFT JOIN f ON f.project_id = p.id "
        "LEFT JOIN t ON t.project_id = p.id "
        "WHERE ($1::text IS NULL OR p.code = upper($1)) "
        "  AND ($2 OR p.manager = $3 OR EXISTS (SELECT 1 FROM projects.project_member pm "
        "       JOIN projects.employee e ON e.id = pm.employee_id "
        "       WHERE pm.project_id = p.id AND e.username = $3)) "
        "ORDER BY p.code", project, access.is_admin(), ana.context.user)
    out = []
    for r in rows:
        r["budget_used_pct"] = (round(r["hours_logged"] / r["budget_hours"] * 100, 1)
                                if r["budget_hours"] else None)
        if access.can_manage(r):
            r["margin"] = r["invoiced"] - r["cost"]
        else:
            r["cost"] = r["margin"] = None     # RNF-008-02
        out.append(r)
    ana.table([{"projeto": r["code"], "cliente": r["customer"], "status": r["status"],
                "h previstas": r["planned_hours"], "h apontadas": r["hours_logged"],
                "orçamento usado %": r["budget_used_pct"],
                "custo": money(r["cost"]) if r["cost"] is not None else "—",
                "faturado": money(r["invoiced"]), "a faturar": money(r["to_invoice"]),
                "margem": money(r["margin"]) if r["margin"] is not None else "—"} for r in out],
              title="Projetos")
    return out
