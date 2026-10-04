# ana:description Despesa prevista do projeto (única ou mensal), para a projeção de viabilidade
# ana:exposed yes
"""RF-021-13. Monthly expenses repeat in every month of the project, so a
longer deadline costs more."""

from ana_lib.projects import access

PARAMS = {
    "project": {"type": "str", "required": True},
    "id": {"type": "int"},
    "description": {"type": "str"},
    "kind": {"type": "str", "default": "other", "label": "tipo", "choices": [["component", "Componentes"], ["pcb", "Placas"], ["supplies", "Insumos"], ["subcontract", "Terceiros"], ["travel", "Viagens"], ["software", "Software"], ["other", "Outros"]]},
    "amount": {"type": "decimal"},
    "monthly": {"type": "bool", "default": False},
    "expected_date": {"type": "date"},
    "rebillable": {"type": "bool", "default": False},
    "markup_pct": {"type": "decimal", "default": 0},
    "remove": {"type": "bool", "default": False},
}


def main(project, id=None, description=None, kind="other", amount=None, monthly=False, expected_date=None,
         rebillable=False, markup_pct=0, remove=False):
    p = access.project(project)
    access.require_manager(p)
    if remove:
        return {"removed": ana.sql_exec("DELETE FROM projects.planned_expense WHERE id = $1 AND project_id = $2",
                                        id, p["id"])}
    if not description or amount is None or amount < 0:
        raise ana.Error("INVALID_PARAMETER", "informe descrição e valor")
    if id is None:
        new_id = ana.sql_value(
            "INSERT INTO projects.planned_expense (project_id, description, kind, amount, monthly, expected_date, "
            "  rebillable, markup_pct, created_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id",
            p["id"], description, kind, amount, monthly, expected_date, rebillable, markup_pct or 0, ana.context.user)
        return {"id": new_id}
    ana.sql_exec("UPDATE projects.planned_expense SET description = $3, kind = $4, amount = $5, monthly = $6, "
                 "expected_date = $7, rebillable = $8, markup_pct = $9 WHERE id = $1 AND project_id = $2",
                 id, p["id"], description, kind, amount, monthly, expected_date, rebillable, markup_pct or 0)
    return {"id": id}
