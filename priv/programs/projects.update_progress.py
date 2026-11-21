# ana:description Atualiza situação e % concluído de uma atividade
# ana:exposed yes
# ana:category Projetos/Planejamento
"""RF-021-04/05, H4. The responsible person, a team member allocated to the
activity, or the manager. Moving to doing/done records actual dates."""

import datetime

from ana_lib.projects import access
from ana_lib.projects import views as V

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto", "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "activity": {"type": "str", "required": True, "label": "atividade", "lookup": {"program": "projects.lookup", "params": {"kind": "activities"}, "depends": ["project"]}},
    "status": {"type": "str", "label": "situação", "choices": [["todo", "A fazer"], ["doing", "Em andamento"], ["review", "Em revisão"], ["done", "Concluído"], ["blocked", "Bloqueado"]]},
    "percent": {"type": "decimal", "label": "% concluído"},
    "note": {"type": "str", "label": "observação"},
}


def main(project, activity, status=None, percent=None, note=None):
    p = access.project(project)
    access.require_active(p)
    t = V.activity(p, activity, lock=True)
    if t["kind"] != "activity":
        raise ana.Error("INVALID_PARAMETER", "andamento é informado nas atividades")
    me = V.employee_of(ana.context.user)
    allowed = access.can_manage(p) or (me and (t["owner_employee_id"] == me["id"] or ana.sql_value(
        "SELECT count(*) FROM projects.allocation WHERE task_id = $1 AND employee_id = $2", t["id"], me["id"])))
    if not allowed:
        raise ana.Error("FORBIDDEN", "só o responsável, quem está alocado ou o gestor")
    if status not in (None, "todo", "doing", "review", "done", "blocked"):
        raise ana.Error("INVALID_PARAMETER", "situação inválida")
    if percent is not None and not (0 <= percent <= 100):
        raise ana.Error("INVALID_PARAMETER", "% concluído entre 0 e 100")
    if status == "done":
        percent = 100
    elif percent is not None and percent == 100 and status is None:
        status = "done"
    elif percent is not None and percent > 0 and status is None and t["status"] == "todo":
        status = "doing"
    today = datetime.date.today()
    new_status = status or t["status"]
    actual_start = t["actual_start"] or (today if new_status in ("doing", "review", "done") else None)
    actual_finish = today if new_status == "done" else None
    notes = t["notes"]
    if note:
        notes = (notes + "\n" if notes else "") + f"{today.isoformat()} {ana.context.user}: {note.strip()}"
    ana.sql_exec(
        "UPDATE projects.task SET status = $2, percent_complete = COALESCE($3, percent_complete), "
        "  actual_start = $4, actual_finish = $5, notes = $6, updated_at = now() WHERE id = $1",
        t["id"], new_status, percent, actual_start, actual_finish, notes)
    return {"activity": t["code"], "status": new_status,
            "percent": percent if percent is not None else t["percent_complete"]}
