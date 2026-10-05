# ana:description Aloca pessoa (ou perfil) a uma atividade: horas por semana ou distribuídas no período
# ana:exposed yes
# ana:command alocar
"""RF-021-03/03a, CA-021-02/02a.

- `week` + `hours`: hours of that week (0 removes).
- `distribute=true` + `hours`: spreads the total over the working weeks
  between start and finish of the activity (planned dates, else schedule).
- `replace_profile` + `employee`: turns a profile allocation into a person,
  keeping the hours.
A person outside the team joins it. Returns the overallocation of the
affected weeks, considering every project, with suggestions.
"""

import datetime

from ana_lib.projects import access
from ana_lib.projects import consulting as C
from ana_lib.projects import views as V

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto", "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "activity": {"type": "str", "required": True, "label": "atividade", "lookup": {"program": "projects.lookup", "params": {"kind": "activities"}, "depends": ["project"]}},
    "employee": {"type": "int", "label": "pessoa", "lookup": {"program": "projects.lookup", "params": {"kind": "employees"}}},
    "profile": {"type": "str", "label": "perfil (quando ainda não há pessoa)", "lookup": {"program": "projects.lookup", "params": {"kind": "profiles"}}},
    "hours": {"type": "decimal", "label": "horas"},
    "week": {"type": "date", "label": "semana (qualquer dia)"},
    "distribute": {"type": "bool", "label": "distribuir o total no período da atividade"},
    "replace_profile": {"type": "str", "label": "trocar alocação deste perfil pela pessoa", "lookup": {"program": "projects.lookup", "params": {"kind": "profiles"}}},
}


def main(project, activity, employee=None, profile=None, hours=None, week=None, distribute=False,
         replace_profile=None):
    p = access.project(project, lock=True)
    access.require_manager(p)
    t = V.activity(p, activity)
    if t["kind"] != "activity":
        raise ana.Error("INVALID_PARAMETER", "aloque pessoas nas atividades, não na fase")
    profile = profile.upper() if profile else None
    if replace_profile:
        if employee is None:
            raise ana.Error("INVALID_PARAMETER", "informe a pessoa que assume a alocação do perfil")
        weeks = replace(p, t, replace_profile.upper(), employee)
    else:
        if (employee is None) == (profile is None):
            raise ana.Error("INVALID_PARAMETER", "informe a pessoa ou o perfil")
        if hours is None or hours < 0:
            raise ana.Error("INVALID_PARAMETER", "informe as horas")
        if employee is not None:
            join_team(p, employee)
        elif not ana.sql_value("SELECT count(*) FROM projects.rate_profile WHERE code = $1", profile):
            raise ana.Error("PROFILE_NOT_FOUND", f"perfil {profile} não existe")
        if distribute:
            start, finish = period(p, t)
            plan = C.distribute(hours, start, finish)
            ana.sql_exec("DELETE FROM projects.allocation WHERE task_id = $1 AND "
                         + ("employee_id = $2" if employee is not None else "profile = $2"),
                         t["id"], employee if employee is not None else profile)
        else:
            plan = {C.monday(week or datetime.date.today()): hours}
        for w, h in plan.items():
            upsert(p, t, employee, profile, w, h)
        weeks = sorted(plan)
    over = []
    if employee is not None and weeks:
        over = C.overallocation([employee], weeks)
        name = ana.sql_value("SELECT name FROM projects.employee WHERE id = $1", employee)
        for o in over:
            sug = C.suggest_moves(employee, o["week"], o["excess"])
            hint = ", ".join(f"{V.fmt(s['hours'])} h em {V.fmt(s['week'])}" for s in sug) or "sem folga próxima"
            ana.log(f"{name}: {V.fmt(o['allocated'])} h alocadas na semana de {V.fmt(o['week'])} para "
                    f"{V.fmt(o['capacity'])} h de capacidade (todos os projetos); sugestão: mover {hint}", "warning")
            o["suggestions"] = sug
    rows = ana.sql(
        "SELECT a.week, a.hours, COALESCE(e.name, 'perfil ' || a.profile) AS who FROM projects.allocation a "
        "LEFT JOIN projects.employee e ON e.id = a.employee_id WHERE a.task_id = $1 ORDER BY a.week, who", t["id"])
    ana.table([{"semana": V.fmt(r["week"]), "pessoa": r["who"], "horas": r["hours"]} for r in rows],
              title=f"Alocação de {t['code']} {t['name']}")
    ana.actions([V.open_view(p, "activity", "Ver atividade", activity=t["code"]),
                 V.open_view(p, "allocation", "Alocação do projeto")], title="Próximo passo")
    return {"activity": t["code"], "allocations": rows, "overallocation": over}


def period(p, t):
    if t["planned_start"] and t["planned_finish"]:
        return t["planned_start"], t["planned_finish"]
    s = C.schedule(p, forecast=False)["items"][t["id"]]
    return t["planned_start"] or s["es"], t["planned_finish"] or s["ef"]


def upsert(p, t, employee, profile, week, hours):
    if hours == 0:
        ana.sql_exec("DELETE FROM projects.allocation WHERE task_id = $1 AND week = $2 AND "
                     + ("employee_id = $3" if employee is not None else "profile = $3"),
                     t["id"], week, employee if employee is not None else profile)
        return
    if employee is not None:
        ana.sql_exec("INSERT INTO projects.allocation (project_id, task_id, week, employee_id, hours) "
                     "VALUES ($1, $2, $3, $4, $5) ON CONFLICT (task_id, employee_id, week) "
                     "WHERE employee_id IS NOT NULL DO UPDATE SET hours = EXCLUDED.hours",
                     p["id"], t["id"], week, employee, hours)
    else:
        ana.sql_exec("INSERT INTO projects.allocation (project_id, task_id, week, profile, hours) "
                     "VALUES ($1, $2, $3, $4, $5) ON CONFLICT (task_id, profile, week) "
                     "WHERE profile IS NOT NULL DO UPDATE SET hours = EXCLUDED.hours",
                     p["id"], t["id"], week, profile, hours)


def replace(p, t, profile, employee):
    rows = ana.sql("SELECT week, hours FROM projects.allocation WHERE task_id = $1 AND profile = $2", t["id"], profile)
    if not rows:
        raise ana.Error("ALLOCATION_NOT_FOUND", f"não há alocação do perfil {profile} em {t['code']}")
    join_team(p, employee)
    # One statement: the profile's weeks move to the person, adding to what they already had.
    ana.sql_exec("WITH moved AS (DELETE FROM projects.allocation WHERE task_id = $2 AND profile = $3 "
                 "  RETURNING week, hours) "
                 "INSERT INTO projects.allocation (project_id, task_id, week, employee_id, hours) "
                 "SELECT $1, $2, week, $4, hours FROM moved "
                 "ON CONFLICT (task_id, employee_id, week) WHERE employee_id IS NOT NULL "
                 "DO UPDATE SET hours = projects.allocation.hours + EXCLUDED.hours",
                 p["id"], t["id"], profile, employee)
    return [r["week"] for r in rows]


def join_team(p, employee):
    e = ana.sql_one("SELECT id, name, profile FROM projects.employee WHERE id = $1 AND active", employee)
    if not e:
        raise ana.Error("EMPLOYEE_NOT_FOUND", f"colaborador {employee} não existe ou está inativo")
    n = ana.sql_exec("INSERT INTO projects.project_member (project_id, employee_id, profile) VALUES ($1, $2, $3) "
                     "ON CONFLICT DO NOTHING", p["id"], employee, e["profile"])
    if n:
        ana.log(f"{e['name']} incluído(a) na equipe do projeto {p['code']} com o perfil {e['profile']}")
