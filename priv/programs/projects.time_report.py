# ana:description Extrato de horas do projeto para o cliente (sem custos)
# ana:exposed yes
# ana:command timereport
"""RF-008-15: statement for the customer — never contains cost."""

import datetime

from ana_lib.projects import access

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto", "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "start": {"type": "date", "label": "de"},
    "end": {"type": "date", "label": "até"},
    "approved_only": {"type": "bool", "default": True, "label": "só aprovados"},
}


def main(project, start=None, end=None, approved_only=True):
    p = access.project(project)
    access.require_manager(p)
    end = end or datetime.date.today()
    start = start or end.replace(day=1)
    rows = ana.sql(
        "SELECT t.entry_date, e.name AS employee, rp.description AS profile, k.code AS task, "
        "       t.hours, t.description "
        "FROM projects.time_entry t JOIN projects.employee e ON e.id = t.employee_id "
        "JOIN projects.rate_profile rp ON rp.code = t.profile JOIN projects.task k ON k.id = t.task_id "
        "WHERE t.project_id = $1 AND t.entry_date BETWEEN $2 AND $3 AND t.billable "
        "  AND (NOT $4 OR t.status IN ('approved', 'invoiced')) AND t.status <> 'rejected' "
        "ORDER BY t.entry_date, e.name", p["id"], start, end, approved_only)
    totals = {}
    for r in rows:
        totals[r["profile"]] = totals.get(r["profile"], 0) + r["hours"]
    ana.table([{"data": r["entry_date"], "colaborador": r["employee"], "perfil": r["profile"],
                "tarefa": r["task"], "horas": r["hours"], "descrição": r["description"]} for r in rows],
              title=f"Extrato de horas — {p['code']} ({start} a {end})")
    ana.table([{"perfil": k, "horas": v} for k, v in sorted(totals.items())], title="Totais por perfil")
    return {"project": p["code"], "start": start, "end": end, "entries": rows,
            "total_hours": sum(totals.values(), 0)}
