# ana:description Conclui marco (fica disponível para faturamento)
# ana:exposed yes
import datetime

from ana_lib.projects import access

PARAMS = {
    "id": {"type": "int", "required": True, "label": "marco (id)"},
    "completed_on": {"type": "date", "label": "concluído em"},
}


def main(id, completed_on=None):
    m = ana.sql_one("SELECT m.id, m.status, p.code FROM projects.milestone m "
                    "JOIN projects.project p ON p.id = m.project_id WHERE m.id = $1 FOR UPDATE", id)
    if not m:
        raise ana.Error("MILESTONE_NOT_FOUND", f"marco {id} não encontrado")
    access.require_manager(access.project(m["code"]))
    if m["status"] != "planned":
        raise ana.Error("MILESTONE_LOCKED", f"marco {id} está {m['status']}")
    ana.sql_exec("UPDATE projects.milestone SET status = 'completed', completed_on = $2 WHERE id = $1",
                 id, completed_on or datetime.date.today())
    return {"id": id, "status": "completed"}
