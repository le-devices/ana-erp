# ana:description Cria ou atualiza colaborador (perfil, custo-hora, login)
# ana:exposed yes
# ana:command employee
# ana:category Projetos/Pessoas e políticas
"""Hourly cost is confidential: only administrators maintain employees."""

from ana_lib.projects import access

PARAMS = {
    "id": {"type": "int", "label": "colaborador (id; vazio = novo)"},
    "name": {"type": "str", "required": True, "label": "nome"},
    "profile": {"type": "str", "required": True, "label": "perfil", "lookup": {"program": "projects.lookup", "params": {"kind": "profiles"}}},
    "hourly_cost": {"type": "decimal", "default": 0, "label": "custo por hora (confidencial)"},
    "username": {"type": "str", "label": "usuário do sistema"},
    "active": {"type": "bool", "default": True, "label": "ativo"},
    "tax_id": {"type": "str", "label": "CPF (vazio = mantém)"},
}


def main(name, profile, hourly_cost=0, username=None, active=True, id=None, tax_id=None):
    access.require_admin()
    profile = profile.strip().upper()
    if not ana.sql_value("SELECT 1 FROM projects.rate_profile WHERE code = $1", profile):
        raise ana.Error("PROFILE_NOT_FOUND", f"perfil {profile} não existe")
    username = (username or "").strip().lower() or None
    # Spec 043: the database checks and formats the CPF (and refuses one already used).
    if id is None:
        new_id = ana.sql_value(
            "INSERT INTO projects.employee (name, username, profile, hourly_cost, active, tax_id) "
            "VALUES ($1, $2, $3, $4, $5, $6) RETURNING id", name, username, profile, hourly_cost, active, tax_id)
        return {"id": new_id, "created": True}
    n = ana.sql_exec(
        "UPDATE projects.employee SET name=$2, username=$3, profile=$4, hourly_cost=$5, active=$6, "
        "tax_id = COALESCE($7, tax_id) WHERE id = $1", id, name, username, profile, hourly_cost, active, tax_id)
    if n != 1:
        raise ana.Error("EMPLOYEE_NOT_FOUND", f"colaborador {id} não existe")
    return {"id": id, "created": False}
