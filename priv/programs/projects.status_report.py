# ana:description Gera relatório de status do projeto (andamento, marcos, riscos, horas, próximos passos)
# ana:exposed yes
"""RF-021-09, CA-021-07. Schedulable (spec 018), e.g. weekly, run as a robot
that manages the project. Content is client-safe: hours and progress, never
cost, rates or margin (RNF-021-02). Without `project`, one report per active
project the user manages."""

import datetime

from ana_lib.projects import access
from ana_lib.projects import consulting as C
from ana_lib.projects import views as V

PARAMS = {
    "project": {"type": "str", "label": "projeto (vazio = todos que eu gerencio)"},
    "days": {"type": "int", "default": 7, "label": "período (dias)"},
    "client_visible": {"type": "bool", "default": True, "label": "visível ao cliente"},
}


def main(project=None, days=7, client_visible=True):
    if project:
        projects = [access.project(project)]
    else:
        projects = ana.sql("SELECT * FROM projects.project WHERE status = 'active' AND ($1 OR manager = $2) "
                           "ORDER BY code", access.is_admin(), ana.context.user)
    out = []
    for p in projects:
        access.require_manager(p)
        out.append(report(p, max(1, min(days, 92)), client_visible))
    return out if not project else out[0]


def report(p, days, client_visible):
    end = datetime.date.today()
    start = end - datetime.timedelta(days=days - 1)
    prog = C.progress(p)
    sched = C.schedule(p)
    t = prog["project"]
    tasks, _ = C.load_plan(p["id"])
    upcoming = [x for x in tasks if x["kind"] == "activity" and x["status"] != "done" and x["client_visible"]
                and sched["items"][x["id"]]["es"] <= end + datetime.timedelta(days=14)]
    done = [x for x in tasks if x["kind"] == "activity" and x["status"] == "done" and x["actual_finish"]
            and start <= x["actual_finish"] <= end and x["client_visible"]]
    hours_period = ana.sql_value("SELECT COALESCE(sum(hours), 0) FROM projects.time_entry WHERE project_id = $1 "
                                 "AND entry_date BETWEEN $2 AND $3 AND status <> 'rejected'", p["id"], start, end)
    content = {
        "project": p["code"], "name": p["name"], "period_start": start, "period_end": end,
        "percent_complete": t["percent_complete"], "spi": t["spi"],
        "forecast_finish": sched["finish"], "due_date": p["due_date"],
        "hours": {"planned": t["bac_hours"], "logged_total": t["ac_hours"], "logged_period": hours_period},
        "phases": [{"name": r["name"], "percent_complete": r["percent_complete"], "planned_hours": r["bac_hours"],
                    "logged_hours": r["ac_hours"]} for r in prog["phases"]],
        "completed": [{"code": x["code"], "name": x["name"], "deliverable": x["deliverable"]} for x in done],
        "next_steps": [{"code": x["code"], "name": x["name"], "start": sched["items"][x["id"]]["es"],
                        "finish": sched["items"][x["id"]]["ef"]} for x in upcoming[:15]],
        "milestones": ana.sql("SELECT description, due_date, status FROM projects.milestone WHERE project_id = $1 "
                              "ORDER BY due_date NULLS LAST", p["id"]),
        "risks": ana.sql("SELECT kind, title, probability * impact AS exposure, action_plan, due_date, status "
                         "FROM projects.risk WHERE project_id = $1 AND client_visible AND status <> 'closed' "
                         "ORDER BY 3 DESC", p["id"]),
        "scope_changes": ana.sql("SELECT number, title, status, est_hours, est_days FROM projects.scope_change "
                                 "WHERE project_id = $1 ORDER BY number", p["id"]),
    }
    rid = ana.sql_value("INSERT INTO projects.status_report (project_id, period_start, period_end, content, "
                        "client_visible, created_by) VALUES ($1, $2, $3, $4, $5, $6) RETURNING id",
                        p["id"], start, end, content, client_visible, ana.context.user)
    ana.metrics([{"label": "% concluído", "value": f"{t['percent_complete']}%"},
                 {"label": "Horas no período", "value": f"{V.fmt(hours_period)} h"},
                 {"label": "Término previsto", "value": V.fmt(sched["finish"]), "hint": f"prazo {V.fmt(p['due_date'])}"}],
                title=f"Status {p['code']} — {V.fmt(start)} a {V.fmt(end)}")
    ana.table([{"fase": f["name"], "% concluído": f["percent_complete"], "h planejadas": f["planned_hours"],
                "h apontadas": f["logged_hours"]} for f in content["phases"]], title="Fases")
    ana.table([{"próximo passo": f"{s['code']} {s['name']}", "de": V.fmt(s["start"]), "até": V.fmt(s["finish"])}
               for s in content["next_steps"]], title="Próximos passos")
    return {"id": rid, "project": p["code"], "content": content}
