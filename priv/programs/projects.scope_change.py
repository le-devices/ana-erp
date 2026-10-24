# ana:description Mudança de escopo: pedido, estimativa, aprovação interna e do cliente, recusa
# ana:exposed yes
# ana:category Projetos/Planejamento
"""RF-021-07, CA-021-05. Customer approval raises the budget (hours, amount,
due date in working days), creates an additional milestone when there is an
amount, and freezes a new baseline; the previous one stays available.

The manager records an approval given outside the system with the approver's name;
customers approve themselves on the portal (projects.client_approvals)."""

from ana_lib.projects import access
from ana_lib.projects import changes
from ana_lib.projects import views as V

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto", "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "action": {"type": "str", "required": True, "label": "ação", "choices": [["request", "Pedir"], ["estimate", "Estimar"], ["approve_internal", "Aprovar internamente"], ["approve_customer", "Registrar aprovação do cliente"], ["reject", "Recusar"]]},
    "number": {"type": "int", "label": "nº da mudança"},
    "title": {"type": "str", "label": "título"},
    "description": {"type": "str", "label": "descrição"},
    "est_hours": {"type": "decimal", "label": "horas estimadas"},
    "est_amount": {"type": "decimal", "label": "valor estimado"},
    "est_days": {"type": "int", "label": "dias a mais no prazo"},
    "customer_approver": {"type": "str", "label": "aprovado por (cliente)"},
    "reason": {"type": "str", "label": "motivo"},
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
    c = ana.sql_one("SELECT id, project_id, number, title, description, requested_by, requested_at, est_hours, "
                    "est_amount, est_days, status, internal_approved_by, internal_approved_at, "
                    "customer_approver, customer_approved_at, rejection_reason, milestone_id, baseline_id FROM projects.scope_change WHERE project_id = $1 AND number = $2 FOR UPDATE",
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
    r = changes.approve_by_customer(p, c, approver)
    p = access.project(p["code"])
    ana.actions([V.open_view(p, "structure", "Incluir as atividades da mudança"),
                 {"label": "Comparar linhas de base", "program": "projects.baselines", "open": True,
                  "params": {"project": p["code"]}}], title="Próximo passo")
    return r
