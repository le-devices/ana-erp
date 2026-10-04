# ana:description Aponta horas de um colaborador numa tarefa de projeto
# ana:exposed yes
# ana:command logtime
"""Time entry (RF-008-07). Without `employee`, logs for the current user.

Passing `id` edits an entry that is still pending or rejected (it goes back
to pending).
"""

import datetime
from decimal import Decimal

from ana_lib.projects import access

PARAMS = {
    "project": {"type": "str", "required": True},
    "task": {"type": "str", "required": True},
    "hours": {"type": "decimal", "required": True},
    "description": {"type": "str", "required": True},
    "entry_date": {"type": "date"},
    "employee": {"type": "int"},
    "id": {"type": "int"},
}


def main(project, task, hours, description, entry_date=None, employee=None, id=None):
    p = access.project(project)
    access.require_active(p)
    entry_date = entry_date or datetime.date.today()
    if entry_date > datetime.date.today():
        raise ana.Error("INVALID_DATE", "não é possível apontar horas em data futura")
    if hours <= 0 or hours > 24 or (hours * 4) % 1 != 0:
        raise ana.Error("INVALID_HOURS", "horas devem ser > 0, ≤ 24 e múltiplas de 0,25")
    if len(description.strip()) < 3:
        raise ana.Error("INVALID_DESCRIPTION", "descreva o que foi feito")

    me = access.current_employee()
    if employee is None:
        if me is None:
            raise ana.Error("EMPLOYEE_NOT_LINKED", "seu usuário não está vinculado a um colaborador")
        employee = me["id"]
    elif (me is None or me["id"] != employee) and not access.can_manage(p):
        raise ana.Error("FORBIDDEN", "só é possível apontar horas para si mesmo")

    member = ana.sql_one("SELECT profile FROM projects.project_member "
                         "WHERE project_id = $1 AND employee_id = $2", p["id"], employee)
    if not member:
        raise ana.Error("NOT_A_MEMBER", f"colaborador {employee} não faz parte do projeto {p['code']}")
    t = ana.sql_one("SELECT id, billable FROM projects.task WHERE project_id = $1 AND code = $2 AND active",
                    p["id"], str(task))
    if not t:
        raise ana.Error("TASK_NOT_FOUND", f"tarefa {task} não encontrada no projeto {p['code']}")

    # Friendly check (the database trigger is the safety net).
    day_total = ana.sql_value(
        "SELECT COALESCE(sum(hours), 0) FROM projects.time_entry "
        "WHERE employee_id = $1 AND entry_date = $2 AND status <> 'rejected' AND id <> COALESCE($3, 0)",
        employee, entry_date, id)
    if day_total + Decimal(hours) > 24:
        raise ana.Error("DAILY_LIMIT", f"já existem {day_total} h apontadas em {entry_date}")

    try:
        if id is None:
            new_id = ana.sql_value(
                "INSERT INTO projects.time_entry (project_id, task_id, employee_id, entry_date, hours, "
                "  description, billable, profile, created_by) "
                "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id",
                p["id"], t["id"], employee, entry_date, hours, description.strip(), t["billable"],
                member["profile"], ana.context.user)
            return {"id": new_id, "status": "pending"}
        n = ana.sql_exec(
            "UPDATE projects.time_entry SET task_id = $2, entry_date = $3, hours = $4, description = $5, "
            "  billable = $6, status = 'pending', rejection_reason = NULL "
            "WHERE id = $1 AND employee_id = $7 AND status IN ('pending', 'rejected')",
            id, t["id"], entry_date, hours, description.strip(), t["billable"], employee)
        if n != 1:
            raise ana.Error("ENTRY_LOCKED", f"apontamento {id} não existe ou já foi aprovado")
        return {"id": id, "status": "pending"}
    except ana.SqlError as e:
        if "DAILY_LIMIT" in e.message:
            raise ana.Error("DAILY_LIMIT", "limite de 24 h por dia excedido") from None
        raise
