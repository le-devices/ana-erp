# ana:description Cria ou atualiza colaborador (perfil, custo-hora, login)
# ana:exposed yes
# ana:command employee
"""Hourly cost is confidential: only administrators maintain employees."""

from ana_lib.projects import access

PARAMS = {
    "id": {"type": "int"},
    "name": {"type": "str", "required": True},
    "profile": {"type": "str", "required": True},
    "hourly_cost": {"type": "decimal", "default": 0},
    "username": {"type": "str"},
    "active": {"type": "bool", "default": True},
}


def main(name, profile, hourly_cost=0, username=None, active=True, id=None):
    access.require_admin()
    profile = profile.strip().upper()
    if not ana.sql_value("SELECT 1 FROM projects.rate_profile WHERE code = $1", profile):
        raise ana.Error("PROFILE_NOT_FOUND", f"perfil {profile} não existe")
    username = (username or "").strip().lower() or None
    if id is None:
        new_id = ana.sql_value(
            "INSERT INTO projects.employee (name, username, profile, hourly_cost, active) "
            "VALUES ($1, $2, $3, $4, $5) RETURNING id", name, username, profile, hourly_cost, active)
        return {"id": new_id, "created": True}
    n = ana.sql_exec(
        "UPDATE projects.employee SET name=$2, username=$3, profile=$4, hourly_cost=$5, active=$6 "
        "WHERE id = $1", id, name, username, profile, hourly_cost, active)
    if n != 1:
        raise ana.Error("EMPLOYEE_NOT_FOUND", f"colaborador {id} não existe")
    return {"id": id, "created": False}
