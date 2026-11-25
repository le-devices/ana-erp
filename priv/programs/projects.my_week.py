# ana:description Minha semana: minhas atividades, alocação e apontamento em um clique
# ana:command semana
# ana:category Projetos/Meu trabalho
"""RF-021-10, CA-021-06: the consultant logs hours and updates progress
right here, without going to other screens."""

import datetime

from ana_lib.projects import consulting as C
from ana_lib.projects import views as V

PARAMS = {"week": {"type": "date", "label": "semana (qualquer dia)"}}


def main(week=None):
    me = V.employee_of(ana.context.user)
    if me is None:
        raise ana.Error("EMPLOYEE_NOT_LINKED", "seu usuário não está vinculado a um colaborador")
    w = C.monday(week or datetime.date.today())
    end = w + datetime.timedelta(days=6)
    rows = ana.sql(
        "WITH mine AS ("
        "  SELECT task_id, sum(hours) AS allocated FROM projects.allocation "
        "  WHERE employee_id = $1 AND week = $2 GROUP BY task_id "
        "  UNION SELECT t.id, 0 FROM projects.task t JOIN projects.project p ON p.id = t.project_id "
        "  WHERE t.owner_employee_id = $1 AND t.status NOT IN ('done') AND t.active AND p.status = 'active'), "
        " logged AS (SELECT task_id, sum(hours) AS hours FROM projects.time_entry "
        "  WHERE employee_id = $1 AND entry_date BETWEEN $2 AND $3 AND status <> 'rejected' GROUP BY task_id) "
        "SELECT p.code AS project, p.name AS project_name, t.code, t.name, t.status, t.percent_complete, "
        "  t.planned_finish, max(m.allocated) AS allocated, COALESCE(l.hours, 0) AS logged "
        "FROM mine m JOIN projects.task t ON t.id = m.task_id JOIN projects.project p ON p.id = t.project_id "
        "LEFT JOIN logged l ON l.task_id = t.id WHERE t.kind = 'activity' "
        "GROUP BY p.code, p.name, t.code, t.name, t.status, t.percent_complete, t.planned_finish, l.hours, t.seq "
        "ORDER BY p.code, t.seq, t.code", me["id"], w, end)
    cap = C.week_capacity([me["id"]], [w])[(me["id"], w)]
    total_alloc = sum((r["allocated"] or 0) for r in rows)
    total_logged = ana.sql_value(
        "SELECT COALESCE(sum(hours), 0) FROM projects.time_entry WHERE employee_id = $1 "
        "AND entry_date BETWEEN $2 AND $3 AND status <> 'rejected'", me["id"], w, end)
    ana.metrics([{"label": "Semana", "value": f"{V.fmt(w)} a {V.fmt(end)}"},
                 {"label": "Capacidade", "value": f"{V.fmt(cap)} h"},
                 {"label": "Alocado", "value": f"{V.fmt(total_alloc)} h",
                  "status": "bad" if total_alloc > cap else "ok"},
                 {"label": "Apontado", "value": f"{V.fmt(total_logged)} h"}], title=f"Olá, {me['name']}")
    today = min(datetime.date.today(), end)
    out = []
    for r in rows:
        out.append({
            "projeto": r["project"], "atividade": f"{r['code']} {r['name']}",
            "situação": V.STATUS_LABEL.get(r["status"]), "%": r["percent_complete"],
            "alocado (h)": r["allocated"] or 0, "apontado (h)": r["logged"], "prazo": V.fmt(r["planned_finish"]),
            "_actions": [
                {"label": "Apontar", "program": "projects.log_time",
                 "params": {"project": r["project"], "task": r["code"]},
                 "ask": {"hours": {"type": "decimal", "label": "horas", "required": True},
                         "description": {"type": "str", "label": "o que foi feito", "required": True},
                         "entry_date": {"type": "date", "label": "data", "default": today.isoformat()}}},
                {"label": "Andamento", "program": "projects.update_progress",
                 "params": {"project": r["project"], "activity": r["code"]},
                 "ask": {"percent": {"type": "decimal", "label": "% concluído"},
                         "status": {"type": "str", "label": "situação (todo, doing, review, done, blocked)"},
                         "note": {"type": "str", "label": "observação"}}},
                {"label": "Projeto", "program": "projects.workspace", "open": True,
                 "params": {"project": r["project"], "view": "activity", "activity": r["code"]}},
            ]})
    ana.table(out, title="Minhas atividades", empty="Nenhuma atividade sua em aberto nesta semana.",
              empty_action={"label": "Apontar horas", "program": "projects.log_time"})
    if not out:
        ana.log("nenhuma atividade alocada a você nesta semana", "info")
    return {"week": w, "capacity": cap, "allocated": total_alloc, "logged": total_logged, "activities": rows}
