# ana:description Cadastra ou altera centro de custo (hierarquia, tipo, responsável)
# ana:exposed yes
# ana:role admin
# ana:category Contabilidade/Custos e orçamento
"""RF-027-01. Admin only. A center with lines posted can be deactivated, never removed."""

PARAMS = {
    "code": {"type": "str", "required": True, "label": "código"},
    "name": {"type": "str", "label": "nome"},
    "parent": {"type": "str", "label": "centro-pai", "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}},
    "kind": {"type": "str", "label": "tipo", "choices": [["operational", "Operacional"], ["administrative", "Administrativo"],
                                                          ["commercial", "Comercial"], ["project", "Projeto"], ["other", "Outro"]]},
    "manager": {"type": "str", "label": "responsável (usuário)"},
    "active": {"type": "bool", "label": "ativo", "default": True},
}


def main(code, name=None, parent=None, kind=None, manager=None, active=True):
    code = code.strip().upper()
    parent = parent.strip().upper() if parent else None
    if parent:
        # No cycles: the parent cannot be this center or one of its descendants.
        loop = ana.sql_value("WITH RECURSIVE d AS (SELECT code FROM finance.cost_center WHERE code = $1 "
                             "UNION ALL SELECT c.code FROM finance.cost_center c JOIN d ON c.parent_code = d.code) "
                             "SELECT count(*) FROM d WHERE code = $2", code, parent)
        if loop:
            raise ana.Error("COST_CENTER_CYCLE", "o centro-pai não pode ser o próprio centro nem um de seus filhos")
    exists = ana.sql_value("SELECT count(*) FROM finance.cost_center WHERE code = $1", code)
    if not exists:
        if not name:
            raise ana.Error("INVALID_PARAMETER", "centro novo exige nome")
        ana.sql_exec("INSERT INTO finance.cost_center (code, name, parent_code, kind, manager, active) "
                     "VALUES ($1, $2, $3, COALESCE($4, 'operational'), $5, $6)", code, name, parent, kind, manager, active)
    else:
        ana.sql_exec("UPDATE finance.cost_center SET name = COALESCE($2, name), parent_code = $3, "
                     "kind = COALESCE($4, kind), manager = COALESCE($5, manager), active = $6 WHERE code = $1",
                     code, name, parent, kind, manager, active)
    return {"code": code, "created": not exists}
