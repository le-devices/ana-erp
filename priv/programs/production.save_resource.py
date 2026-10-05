# ana:description Recurso de produção (máquina, bancada, linha ou pessoas) com capacidade e exceções
# ana:exposed yes
"""RF-014-03. Exceptions override the hours of a day (holiday, maintenance, vacation)."""

PARAMS = {
    "code": {"type": "str", "required": True, "label": "código"},
    "name": {"type": "str", "required": True, "label": "nome"},
    "kind": {"type": "str", "default": "bench", "label": "tipo",
             "choices": [["machine", "Máquina"], ["bench", "Bancada"], ["line", "Linha"], ["people", "Pessoas"]]},
    "daily_hours": {"type": "decimal", "default": 8, "label": "horas por dia"},
    "efficiency_pct": {"type": "decimal", "default": 100, "label": "eficiência %"},
    "cost_per_hour": {"type": "decimal", "default": 0, "label": "custo por hora"},
    "profile": {"type": "str", "label": "perfil (pessoas)", "lookup": {"program": "projects.lookup", "params": {"kind": "profiles"}}},
    "exceptions": {"type": "list", "label": "exceções", "help": '[{"day": "2026-12-24", "hours": 4, "reason": "véspera"}]'},
    "active": {"type": "bool", "default": True, "label": "ativo"},
}


def main(code, name, kind="bench", daily_hours=8, efficiency_pct=100, cost_per_hour=0, profile=None, exceptions=None,
         active=True):
    code = code.strip().upper()
    ana.sql_exec("INSERT INTO production.resource (code, name, kind, daily_hours, efficiency_pct, cost_per_hour, profile, active) "
                 "VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, "
                 "kind = EXCLUDED.kind, daily_hours = EXCLUDED.daily_hours, efficiency_pct = EXCLUDED.efficiency_pct, "
                 "cost_per_hour = EXCLUDED.cost_per_hour, profile = EXCLUDED.profile, active = EXCLUDED.active",
                 code, name, kind, daily_hours, efficiency_pct, cost_per_hour, profile.upper() if profile else None, active)
    if exceptions:
        ana.sql_batch("INSERT INTO production.resource_calendar (resource_code, day, hours, reason) VALUES ($1, $2::text::date, $3, $4) "
                      "ON CONFLICT (resource_code, day) DO UPDATE SET hours = EXCLUDED.hours, reason = EXCLUDED.reason",
                      [[code, str(e["day"]), e.get("hours", 0), e.get("reason") or ""] for e in exceptions])
    return {"code": code}
