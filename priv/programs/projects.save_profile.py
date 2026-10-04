# ana:description Cria ou atualiza perfil profissional e seu valor-hora padrão
# ana:exposed yes
# ana:command profile
from ana_lib.projects import access

PARAMS = {
    "code": {"type": "str", "required": True},
    "description": {"type": "str", "required": True},
    "hourly_rate": {"type": "decimal", "required": True},
    "active": {"type": "bool", "default": True},
}


def main(code, description, hourly_rate, active=True):
    access.require_admin()
    if hourly_rate < 0:
        raise ana.Error("INVALID_VALUE", "valor-hora não pode ser negativo")
    code = code.strip().upper()
    ana.sql_exec(
        "INSERT INTO projects.rate_profile (code, description, hourly_rate, active) VALUES ($1, $2, $3, $4) "
        "ON CONFLICT (code) DO UPDATE SET description = EXCLUDED.description, "
        "hourly_rate = EXCLUDED.hourly_rate, active = EXCLUDED.active",
        code, description, hourly_rate, active)
    return {"code": code}
