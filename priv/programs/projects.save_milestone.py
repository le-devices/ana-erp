# ana:description Cria ou altera marco de valor fixo (ex.: protótipo)
# ana:exposed yes
# ana:command milestone
from ana_lib.projects import access

PARAMS = {
    "project": {"type": "str", "required": True},
    "description": {"type": "str", "required": True},
    "amount": {"type": "decimal", "required": True},
    "due_date": {"type": "date"},
    "id": {"type": "int"},
}


def main(project, description, amount, due_date=None, id=None):
    p = access.project(project)
    access.require_manager(p)
    if amount <= 0:
        raise ana.Error("INVALID_VALUE", "valor do marco deve ser positivo")
    if id is None:
        new_id = ana.sql_value(
            "INSERT INTO projects.milestone (project_id, description, amount, due_date) "
            "VALUES ($1, $2, $3, $4) RETURNING id", p["id"], description, amount, due_date)
        return {"id": new_id}
    n = ana.sql_exec(
        "UPDATE projects.milestone SET description = $3, amount = $4, due_date = $5 "
        "WHERE id = $1 AND project_id = $2 AND status = 'planned'", id, p["id"], description, amount, due_date)
    if n != 1:
        raise ana.Error("MILESTONE_LOCKED", f"marco {id} não existe ou não está mais previsto")
    return {"id": id}
