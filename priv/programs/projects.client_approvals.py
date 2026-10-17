# ana:description Aprovações do cliente: entregáveis concluídos e mudanças de escopo (portal)
# ana:portal yes
# ana:command aprovacoes
"""Spec 021 (H8, T-021-11) on the portal of spec 016. The customer sees, for its own projects
only, the finished deliverables waiting for acceptance and the scope changes approved
internally and waiting for its decision; it accepts or rejects (with a reason). Approving a
change raises budget and due date and freezes a new baseline, as in the manager's screen."""

from ana_lib.projects import access
from ana_lib.projects import changes

PARAMS = {
    "action": {"type": "str", "default": "list", "label": "ação",
               "choices": [["list", "Ver pendências"], ["accept_deliverable", "Aceitar entregável"],
                           ["reject_deliverable", "Recusar entregável"], ["approve_change", "Aprovar mudança"],
                           ["reject_change", "Recusar mudança"]]},
    "project": {"type": "str", "label": "projeto"},
    "activity": {"type": "str", "label": "atividade"},
    "number": {"type": "int", "label": "nº da mudança"},
    "comment": {"type": "str", "label": "comentário (obrigatório ao recusar)"},
    "customer": {"type": "int", "label": "cliente (só para usuários internos)"},
}


def own_project(code, party):
    p = access.project(code)
    if int(p["customer_id"]) != int(party):
        raise ana.Error("PROJECT_NOT_FOUND", f"projeto {code} não encontrado")      # never reveal others' projects
    return p


def main(action="list", project=None, activity=None, number=None, comment=None, customer=None):
    party = ana.context.party or customer
    if not party:
        raise ana.Error("INVALID_PARAMETER", "informe o cliente")
    if ana.context.party and customer and int(customer) != int(ana.context.party):
        raise ana.Error("FORBIDDEN", "a conta do portal só vê os próprios projetos")
    if action == "list":
        return pending(int(party))
    p = own_project(project or "", party)
    if action in ("accept_deliverable", "reject_deliverable"):
        t = ana.sql_one("SELECT id, code, name, deliverable, status FROM projects.task WHERE project_id = $1 AND code = $2 "
                        "AND active AND client_visible AND deliverable IS NOT NULL AND deliverable <> ''", p["id"], str(activity))
        if not t:
            raise ana.Error("TASK_NOT_FOUND", f"entregável {activity} não encontrado")
        if t["status"] != "done":
            raise ana.Error("INVALID_STATE", "o entregável ainda não foi concluído")
        decision = "accepted" if action == "accept_deliverable" else "rejected"
        if decision == "rejected" and len((comment or "").strip()) < 3:
            raise ana.Error("INVALID_PARAMETER", "diga o motivo da recusa")
        ana.sql_exec("INSERT INTO projects.deliverable_acceptance (task_id, decision, comment, decided_by) "
                     "VALUES ($1, $2, $3, $4)", t["id"], decision, (comment or "").strip(), ana.context.user)
        completed = 0
        if decision == "accepted":
            # Spec 038 (RF-038-12, CA-038-13): the milestone tied to this deliverable is ready to invoice.
            completed = ana.sql_exec("UPDATE projects.milestone SET status = 'completed', completed_on = current_date "
                                     "WHERE task_id = $1 AND status = 'planned'", t["id"])
        return {"project": p["code"], "activity": t["code"], "decision": decision, "milestones_completed": completed}
    if action in ("approve_change", "reject_change"):
        c = ana.sql_one("SELECT id, project_id, number, title, est_hours, est_amount, est_days, status "
                        "FROM projects.scope_change WHERE project_id = $1 AND number = $2 FOR UPDATE", p["id"], number)
        if not c:
            raise ana.Error("CHANGE_NOT_FOUND", f"mudança {number} não encontrada")
        if c["status"] != "approved_internal":
            raise ana.Error("INVALID_STATE", "a mudança não está aguardando a sua aprovação")
        if action == "reject_change":
            if len((comment or "").strip()) < 3:
                raise ana.Error("INVALID_PARAMETER", "diga o motivo da recusa")
            ana.sql_exec("UPDATE projects.scope_change SET status = 'rejected', rejection_reason = $2 WHERE id = $1",
                         c["id"], f"recusada pelo cliente ({ana.context.user}): {comment.strip()}")
            return {"project": p["code"], "number": number, "status": "rejected"}
        access.project(p["code"], lock=True)
        r = changes.approve_by_customer(p, c, ana.context.user)
        return {"project": p["code"], "number": number, "status": r["status"]}
    raise ana.Error("INVALID_PARAMETER", f"ação desconhecida: {action}")


def pending(party):
    deliverables = ana.sql(
        "SELECT p.code AS project, t.code, t.name, t.deliverable, t.acceptance_criteria, t.actual_finish "
        "FROM projects.task t JOIN projects.project p ON p.id = t.project_id "
        "WHERE p.customer_id = $1 AND t.active AND t.client_visible AND t.status = 'done' "
        "  AND t.deliverable IS NOT NULL AND t.deliverable <> '' "
        "  AND NOT EXISTS (SELECT 1 FROM projects.deliverable_acceptance a WHERE a.task_id = t.id AND a.decision = 'accepted') "
        "ORDER BY p.code, t.code LIMIT 200", party)
    scope = ana.sql(
        "SELECT p.code AS project, c.number, c.title, c.description, c.est_hours, c.est_amount, c.est_days "
        "FROM projects.scope_change c JOIN projects.project p ON p.id = c.project_id "
        "WHERE p.customer_id = $1 AND c.status = 'approved_internal' ORDER BY p.code, c.number LIMIT 200", party)
    me = "projects.client_approvals"
    ana.table([{"projeto": d["project"], "entregável": f"{d['code']} {d['deliverable']}", "critério de aceite": d["acceptance_criteria"],
                "concluído em": d["actual_finish"],
                "_actions": [{"label": "Aceitar", "program": me, "style": "primary",
                              "params": {"action": "accept_deliverable", "project": d["project"], "activity": d["code"]}},
                             {"label": "Recusar", "program": me,
                              "params": {"action": "reject_deliverable", "project": d["project"], "activity": d["code"]},
                              "ask": {"comment": {"type": "str", "label": "motivo", "required": True}}}]}
               for d in deliverables], title="Entregáveis aguardando seu aceite")
    ana.table([{"projeto": s["project"], "mudança": f"{s['number']} — {s['title']}", "descrição": s["description"],
                "horas": s["est_hours"], "valor": s["est_amount"], "dias": s["est_days"],
                "_actions": [{"label": "Aprovar", "program": me, "style": "primary",
                              "params": {"action": "approve_change", "project": s["project"], "number": s["number"]},
                              "confirm": f"Aprovar a mudança {s['number']}? Valor e prazo do projeto serão ajustados."},
                             {"label": "Recusar", "program": me,
                              "params": {"action": "reject_change", "project": s["project"], "number": s["number"]},
                              "ask": {"comment": {"type": "str", "label": "motivo", "required": True}}}]}
               for s in scope], title="Mudanças de escopo aguardando sua aprovação")
    return {"deliverables": [f"{d['project']}/{d['code']}" for d in deliverables],
            "changes": [f"{s['project']}/{s['number']}" for s in scope]}
