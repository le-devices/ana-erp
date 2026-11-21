# ana:description Alocação de horas em grade: pessoa e atividade por semana, com planejado × apontado × disponível
# ana:exposed yes
# ana:category Projetos/Planejamento
"""Spec 021 (RF-021-03) with the planning grid of spec 020 (RF-020-15/16): one row per person (or profile) ×
activity of the project, one column per week; apontado = hours logged (not rejected). Saved by
projects.save_allocation_plan, which applies the same rules as projects.allocate (manager, team, overallocation)."""

import datetime

from ana_lib.projects import access
from ana_lib.projects import consulting as C

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto", "order": 1,
                "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "start": {"type": "date", "label": "a partir da semana de", "order": 2},
    "weeks": {"type": "int", "default": 8, "label": "semanas", "order": 3},
}
MAX_WEEKS = 26


def main(project, start=None, weeks=8):
    p = access.project(project)
    first = C.monday(start or datetime.date.today())
    weeks = max(1, min(int(weeks or 8), MAX_WEEKS))
    days = [first + datetime.timedelta(weeks=i) for i in range(weeks)]
    last = days[-1] + datetime.timedelta(days=7)
    planned = ana.sql(
        "SELECT a.week, a.hours, t.code AS activity, t.name AS activity_name, a.employee_id, a.profile, e.name "
        "FROM projects.allocation a JOIN projects.task t ON t.id = a.task_id LEFT JOIN projects.employee e ON e.id = a.employee_id "
        "WHERE a.project_id = $1 AND a.week >= $2 AND a.week < $3", p["id"], first, last)
    logged = ana.sql(
        "SELECT date_trunc('week', x.entry_date)::date AS week, sum(x.hours) AS hours, t.code AS activity, t.name AS activity_name, "
        "  x.employee_id, NULL::text AS profile, e.name FROM projects.time_entry x JOIN projects.task t ON t.id = x.task_id "
        "JOIN projects.employee e ON e.id = x.employee_id WHERE x.project_id = $1 AND x.status <> 'rejected' "
        "AND x.entry_date >= $2 AND x.entry_date < $3 GROUP BY 1, 3, 4, 5, 7", p["id"], first, last)
    rows = {}
    for kind, data in (("values", planned), ("consumed", logged)):
        for r in data:
            who = f"e:{r['employee_id']}" if r["employee_id"] is not None else f"p:{r['profile']}"
            label = r["name"] if r["employee_id"] is not None else f"perfil {r['profile']}"
            row = rows.setdefault((who, r["activity"]), {"key": {"who": who, "activity": r["activity"]},
                                                         "labels": {"who": label, "activity": f"{r['activity']} {r['activity_name']}"},
                                                         "values": {}, "consumed": {}})
            row[kind][r["week"].isoformat()] = r["hours"]
    ana.grid(sorted(rows.values(), key=lambda r: (r["labels"]["who"], r["key"]["activity"])), decimals=1, unit="h",
             title=f"Alocação de horas — {p['code']} {p['name']}",
             dimensions=[{"key": "who", "label": "Pessoa ou perfil"}, {"key": "activity", "label": "Atividade"}],
             periods=[{"key": d.isoformat(), "label": f"{d:%d/%m}"} for d in days],
             value_label="Planejado", consumed_label="Apontado", available_label="Disponível", version=version(p["id"], first, last),
             add={"who": {"program": "projects.lookup", "params": {"kind": "employees"}},
                  "activity": {"program": "projects.lookup", "params": {"kind": "activities", "project": p["code"]}}},
             save={"program": "projects.save_allocation_plan", "params": {"project": p["code"], "start": first.isoformat(), "weeks": weeks}})
    return {"rows": len(rows), "weeks": weeks, "version": version(p["id"], first, last)}


def version(project_id, first, last):
    return ana.sql_value("SELECT md5(COALESCE(string_agg(concat_ws(';', task_id, week, employee_id, profile, hours), '|' "
                         "ORDER BY task_id, week, employee_id, profile), '')) FROM projects.allocation "
                         "WHERE project_id = $1 AND week >= $2 AND week < $3", project_id, first, last)
