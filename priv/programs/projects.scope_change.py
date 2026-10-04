# ana:description Mudança de escopo: pedido, estimativa, aprovação interna e do cliente, recusa
# ana:exposed yes
"""RF-021-07, CA-021-05. Customer approval raises the budget (hours, amount,
due date in working days), creates an additional milestone when there is an
amount, and freezes a new baseline; the previous one stays available.

Until the client portal (spec 016) exists, the manager records the
customer's approval with the approver's name."""

from ana_lib.projects import access
from ana_lib.projects import consulting as C
from ana_lib.projects import finance as F
from ana_lib.projects import views as V

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto", "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "action": {"type": "str", "required": True, "label": "ação", "choices": [["request", "Pedir"], ["estimate", "Estimar"], ["approve_internal", "Aprovar internamente"], ["approve_customer", "Registrar aprovação do cliente"], ["reject", "Recusar"]]},
    "number": {"type": "int", "label": "nº da mudança"},
    "title": {"type": "str"},
    "description": {"type": "str"},
    "est_hours": {"type": "decimal"},
    "est_amount": {"type": "decimal"},
    "est_days": {"type": "int"},
    "customer_approver": {"type": "str"},
    "reason": {"type": "str"},
}

NEXT = {"estimate": ("requested", "estimated"), "approve_internal": ("estimated", "approved_internal"),
        "approve_customer": ("approved_internal", "approved")}


def main(project, action, number=None, title=None, description=None, est_hours=None, est_amount=None,
         est_days=None, customer_approver=None, reason=None):
    p = access.project(project, lock=True)
    if action == "request":
        V.require_view(p)
        if not title or len(title.strip()) < 3:
            raise ana.Error("INVALID_PARAMETER", "descreva a mudança (título)")
        n = ana.sql_value("SELECT COALESCE(max(number), 0) + 1 FROM projects.scope_change WHERE project_id = $1", p["id"])
        ana.sql_exec("INSERT INTO projects.scope_change (project_id, number, title, description, requested_by) "
                     "VALUES ($1, $2, $3, $4, $5)", p["id"], n, title.strip(), description or "", ana.context.user)
        return {"project": p["code"], "number": n, "status": "requested"}
    access.require_manager(p)
    if number is None:
        raise ana.Error("INVALID_PARAMETER", "informe o número da mudança")
    c = ana.sql_one("SELECT * FROM projects.scope_change WHERE project_id = $1 AND number = $2 FOR UPDATE",
                    p["id"], number)
    if not c:
        raise ana.Error("CHANGE_NOT_FOUND", f"mudança {number} não encontrada")
    if action == "reject":
        if c["status"] in ("approved", "rejected"):
            raise ana.Error("INVALID_STATE", f"mudança {number} já está {c['status']}")
        ana.sql_exec("UPDATE projects.scope_change SET status = 'rejected', rejection_reason = $2 WHERE id = $1",
                     c["id"], reason or "")
        return {"number": number, "status": "rejected"}
    if action not in NEXT:
        raise ana.Error("INVALID_PARAMETER", f"ação desconhecida: {action}")
    before, after = NEXT[action]
    if c["status"] != before:
        raise ana.Error("INVALID_STATE", f"mudança {number} está {c['status']}; esperado {before}")
    if action == "estimate":
        if est_hours is None:
            raise ana.Error("INVALID_PARAMETER", "estimativa exige horas")
        ana.sql_exec("UPDATE projects.scope_change SET status = 'estimated', est_hours = $2, est_amount = $3, "
                     "est_days = $4 WHERE id = $1", c["id"], est_hours, est_amount, est_days)
    elif action == "approve_internal":
        ana.sql_exec("UPDATE projects.scope_change SET status = 'approved_internal', internal_approved_by = $2, "
                     "internal_approved_at = now() WHERE id = $1", c["id"], ana.context.user)
    else:
        if not customer_approver:
            raise ana.Error("INVALID_PARAMETER", "informe quem aprovou pelo cliente")
        return approve_customer(p, c, customer_approver)
    return {"number": number, "status": after}


def approve_customer(p, c, approver):
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
    ana.actions([V.open_view(p, "structure", "Incluir as atividades da mudança"),
                 {"label": "Comparar linhas de base", "program": "projects.baselines", "open": True,
                  "params": {"project": p["code"]}}], title="Próximo passo")
    return {"number": c["number"], "status": "approved", "milestone_id": milestone, "baseline": base["baseline"]}
