# ana:description Quadro de alocação: pessoas × semanas em todos os projetos, sobrealocação e folga
# ana:command alocacao
# ana:category Projetos/Planejamento
"""RF-021-03/03a. Allocated / capacity per person and week, all projects;
demand still allocated only to profiles (no person yet)."""

import datetime

from ana_lib.projects import access
from ana_lib.projects import consulting as C
from ana_lib.projects import views as V

PARAMS = {
    "start": {"type": "date", "label": "a partir de"},
    "weeks": {"type": "int", "default": 8, "label": "semanas"},
    "profile": {"type": "str", "label": "perfil", "lookup": {"program": "projects.lookup", "params": {"kind": "profiles"}}},
    "project": {"type": "str", "label": "só a equipe deste projeto", "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
}


def main(start=None, weeks=8, profile=None, project=None):
    ws = V.weeks_from(start or datetime.date.today(), max(1, min(weeks, 26)))
    if project:
        p = access.project(project)
        V.require_view(p)
        people = [r["employee_id"] for r in ana.sql(
            "SELECT employee_id FROM projects.project_member WHERE project_id = $1", p["id"])]
    else:
        if not access.is_admin() and not ana.sql_value(
                "SELECT count(*) FROM projects.project WHERE manager = $1", ana.context.user):
            raise ana.Error("FORBIDDEN", "quadro geral de alocação: gestores de projeto e administradores")
        people = [r["id"] for r in ana.sql(
            "SELECT id FROM projects.employee WHERE active AND ($1::text IS NULL OR profile = upper($1))", profile)]
    over = V.people(people, ws, title="Pessoas × semanas")
    demand = ana.sql(
        "SELECT a.profile, a.week, sum(a.hours) AS hours, string_agg(DISTINCT p.code, ', ') AS projects "
        "FROM projects.allocation a JOIN projects.project p ON p.id = a.project_id "
        "WHERE a.profile IS NOT NULL AND a.week = ANY($1::date[]) "
        "  AND ($2::text IS NULL OR a.profile = upper($2)) GROUP BY a.profile, a.week ORDER BY a.profile, a.week",
        ws, profile)
    if demand:
        ana.table([{"perfil": d["profile"], "semana": V.fmt(d["week"]), "horas sem pessoa": d["hours"],
                    "projetos": d["projects"]} for d in demand], title="Demanda alocada só por perfil")
    return {"weeks": ws, "overallocation": over, "profile_demand": demand}
