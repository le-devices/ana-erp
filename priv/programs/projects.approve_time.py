# ana:description Aprova ou rejeita horas pendentes de um projeto
# ana:exposed yes
# ana:command approve
# ana:category Projetos/Faturamento e custos
"""Approval freezes hourly rate (project → profile) and hourly cost (RF-008-09).

Without `ids`, acts on every pending entry up to `through` (default: today).
"""

import datetime

from ana_lib.projects import access

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto", "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "ids": {"type": "list", "label": "apontamentos (ids)"},
    "through": {"type": "date", "label": "até a data"},
    "reject": {"type": "bool", "default": False, "label": "recusar"},
    "reason": {"type": "str", "label": "motivo"},
}


def main(project, ids=None, through=None, reject=False, reason=None):
    p = access.project(project)
    access.require_manager(p)
    through = through or datetime.date.today()
    ids = [int(i) for i in ids] if ids else None
    if reject:
        if not reason or len(reason.strip()) < 3:
            raise ana.Error("REASON_REQUIRED", "informe o motivo da rejeição")
        n = ana.sql_exec(
            "UPDATE projects.time_entry SET status = 'rejected', rejection_reason = $4 "
            "WHERE project_id = $1 AND status = 'pending' AND entry_date <= $2 "
            "  AND ($3::bigint[] IS NULL OR id = ANY($3))", p["id"], through, ids, reason.strip())
        return {"rejected": n}
    r = ana.sql_one(
        "WITH approved AS ("
        "  UPDATE projects.time_entry t SET status = 'approved', approved_by = $4, approved_at = now(), "
        "    hourly_rate = COALESCE((SELECT pr.hourly_rate FROM projects.project_rate pr "
        "                            WHERE pr.project_id = t.project_id AND pr.profile = t.profile), "
        "                           rp.hourly_rate), "
        "    hourly_cost = e.hourly_cost "
        "  FROM projects.rate_profile rp, projects.employee e "
        "  WHERE t.project_id = $1 AND t.status = 'pending' AND t.entry_date <= $2 "
        "    AND ($3::bigint[] IS NULL OR t.id = ANY($3)) "
        "    AND rp.code = t.profile AND e.id = t.employee_id "
        "  RETURNING t.hours) "
        "SELECT count(*) AS entries, COALESCE(sum(hours), 0) AS hours FROM approved",
        p["id"], through, ids, ana.context.user)
    ana.log(f"{r['entries']} apontamento(s) aprovado(s), {r['hours']} h")
    return {"approved": r["entries"], "hours": r["hours"]}
