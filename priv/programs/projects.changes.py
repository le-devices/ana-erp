# ana:description Mudanças de escopo: aprovação pelo cliente (tela do gerente e portal)
# ana:kind library
"""Shared by projects.scope_change and projects.client_approvals (spec 021, H8)."""

import ana

from ana_lib.projects import access
from ana_lib.projects import consulting as C
from ana_lib.projects import finance as F


def approve_by_customer(p, c, approver):
    """Customer approval (RF-021-07): budget and due date grow, an additional milestone holds the
    amount and a new baseline is frozen. Shared by the manager screen and the customer portal."""
    due = p["due_date"]
    if due and c["est_days"]:
        cal = C.Calendar.around(due)
        due = cal.add(cal.roll(due), c["est_days"])
    ana.sql_exec(
        "UPDATE projects.project SET budget_hours = COALESCE(budget_hours, 0) + COALESCE($2::numeric, 0), "
        "  budget_amount = CASE WHEN $3::numeric IS NULL THEN budget_amount ELSE COALESCE(budget_amount, 0) + $3 END, "
        "  due_date = COALESCE($4, due_date) WHERE id = $1", p["id"], c["est_hours"], c["est_amount"], due)
    milestone = None
    if c["est_amount"]:
        milestone = ana.sql_value(
            "INSERT INTO projects.milestone (project_id, description, amount, due_date) VALUES ($1, $2, $3, $4) "
            "RETURNING id", p["id"], f"Mudança de escopo {c['number']}: {c['title']}", c["est_amount"], due)
    ana.sql_exec("UPDATE projects.scope_change SET status = 'approved', customer_approver = $2, "
                 "customer_approved_at = now(), milestone_id = $3 WHERE id = $1", c["id"], approver, milestone)
    base = C.create_baseline(p, f"mudança de escopo {c['number']}: {c['title']}", c["id"])
    p = access.project(p["code"])
    F.check_and_record(p, base["baseline"], f"mudança de escopo {c['number']} aprovada pelo cliente ({approver})")
    ana.sql_exec("UPDATE projects.scope_change SET baseline_id = (SELECT id FROM projects.baseline "
                 "WHERE project_id = $2 AND number = $3) WHERE id = $1", c["id"], p["id"], base["baseline"])
    return {"number": c["number"], "status": "approved", "milestone_id": milestone, "baseline": base["baseline"]}
