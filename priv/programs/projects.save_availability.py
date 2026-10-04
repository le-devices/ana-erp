# ana:description Jornada semanal e ausências (férias, licenças) de um colaborador
# ana:exposed yes
"""RF-021-03: capacity = weekly hours × working days / 5, minus absences and
holidays (scheduler.holiday). Admin, or the person for their own absences."""

from ana_lib.projects import access
from ana_lib.projects import views as V

PARAMS = {
    "employee": {"type": "int", "label": "colaborador (vazio = eu)"},
    "weekly_hours": {"type": "decimal", "label": "jornada semanal (h)"},
    "absence_from": {"type": "date", "label": "ausência de"},
    "absence_to": {"type": "date", "label": "ausência até"},
    "kind": {"type": "str", "default": "vacation", "label": "vacation, leave, training, other"},
    "remove_absence": {"type": "int", "label": "remover ausência (id)"},
}


def main(employee=None, weekly_hours=None, absence_from=None, absence_to=None, kind="vacation", remove_absence=None):
    me = V.employee_of(ana.context.user)
    if employee is None:
        if me is None:
            raise ana.Error("EMPLOYEE_NOT_LINKED", "seu usuário não está vinculado a um colaborador")
        employee = me["id"]
    own = me is not None and me["id"] == employee
    if weekly_hours is not None:
        access.require_admin()
        if not 0 <= weekly_hours <= 80:
            raise ana.Error("INVALID_PARAMETER", "jornada entre 0 e 80 h")
        if ana.sql_exec("UPDATE projects.employee SET weekly_hours = $2 WHERE id = $1", employee, weekly_hours) != 1:
            raise ana.Error("EMPLOYEE_NOT_FOUND", f"colaborador {employee} não existe")
    if absence_from or absence_to or remove_absence:
        if not (own or access.is_admin()):
            raise ana.Error("FORBIDDEN", "ausências de outra pessoa: só administradores")
    if remove_absence:
        ana.sql_exec("DELETE FROM projects.absence WHERE id = $1 AND employee_id = $2", remove_absence, employee)
    if absence_from or absence_to:
        if not (absence_from and absence_to) or absence_to < absence_from:
            raise ana.Error("INVALID_PARAMETER", "informe o período da ausência")
        ana.sql_exec("INSERT INTO projects.absence (employee_id, from_date, to_date, kind) VALUES ($1, $2, $3, $4)",
                     employee, absence_from, absence_to, kind)
    rows = ana.sql("SELECT id, from_date, to_date, kind FROM projects.absence WHERE employee_id = $1 "
                   "AND to_date >= current_date - 30 ORDER BY from_date", employee)
    ana.table([{"id": r["id"], "de": V.fmt(r["from_date"]), "até": V.fmt(r["to_date"]), "tipo": r["kind"]}
               for r in rows], title="Ausências")
    return {"employee": employee, "absences": rows}
