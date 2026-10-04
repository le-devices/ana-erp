# ana:description Política de margem e cenários padrão das projeções (empresa)
# ana:exposed yes
"""RF-021-14a/15. Admin only. Without parameters, shows the current policy."""

from ana_lib.projects import access

FIELDS = ["target_margin_pct", "min_margin_pct", "overhead_pct",
          "optimistic_hours_pct", "optimistic_cost_pct", "optimistic_rate_pct", "optimistic_delay_weeks",
          "pessimistic_hours_pct", "pessimistic_cost_pct", "pessimistic_rate_pct", "pessimistic_delay_weeks"]
PARAMS = {
    "target_margin_pct": {"type": "decimal", "label": "margem alvo (%)"},
    "min_margin_pct": {"type": "decimal", "label": "margem mínima (%)"},
    "overhead_pct": {"type": "decimal", "label": "despesas gerais (% do custo de pessoal)"},
    "optimistic_hours_pct": {"type": "decimal", "label": "otimista: horas (%)"},
    "optimistic_cost_pct": {"type": "decimal", "label": "otimista: custo (%)"},
    "optimistic_rate_pct": {"type": "decimal", "label": "otimista: valor-hora (%)"},
    "optimistic_delay_weeks": {"type": "int", "label": "otimista: atraso (semanas)"},
    "pessimistic_hours_pct": {"type": "decimal", "label": "pessimista: horas (%)"},
    "pessimistic_cost_pct": {"type": "decimal", "label": "pessimista: custo (%)"},
    "pessimistic_rate_pct": {"type": "decimal", "label": "pessimista: valor-hora (%)"},
    "pessimistic_delay_weeks": {"type": "int", "label": "pessimista: atraso (semanas)"},
    "profile_costs": {"type": "dict", "label": "custo-hora padrão por perfil, ex. {\"HW\": 95}"},
}


def main(profile_costs=None, **f):
    if any(v is not None for v in f.values()) or profile_costs:
        access.require_admin()
        sets = [f"{k} = COALESCE(${n + 1}, {k})" for n, k in enumerate(FIELDS)]
        try:
            ana.sql_exec(f"UPDATE projects.policy SET {', '.join(sets)}, updated_by = ${len(FIELDS) + 1}, "
                         f"updated_at = now() WHERE id = 1", *[f.get(k) for k in FIELDS], ana.context.user)
        except ana.SqlError:
            raise ana.Error("INVALID_PARAMETER", "valores fora do permitido (margem mínima ≤ alvo; "
                                                 "variações entre -90% e 500%)") from None
        for code, cost in (profile_costs or {}).items():
            if ana.sql_exec("UPDATE projects.rate_profile SET standard_cost = $2 WHERE code = $1",
                            str(code).upper(), cost) != 1:
                raise ana.Error("PROFILE_NOT_FOUND", f"perfil {code} não existe")
    pol = ana.sql_one("SELECT * FROM projects.policy WHERE id = 1")
    if access.is_admin():
        ana.table([{"perfil": r["code"], "valor-hora": r["hourly_rate"], "custo padrão": r["standard_cost"] or "média das pessoas"}
                   for r in ana.sql("SELECT code, hourly_rate, standard_cost FROM projects.rate_profile ORDER BY code")],
                  title="Perfis")
    ana.table([{"parâmetro": k, "valor": pol[k]} for k in FIELDS], title="Política de projeção")
    return {k: pol[k] for k in FIELDS}
