# ana:description Política de margem e cenários padrão das projeções (empresa)
# ana:exposed yes
# ana:category Projetos/Pessoas e políticas
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
        try:
            ana.sql_exec("UPDATE projects.policy SET target_margin_pct = COALESCE($1, target_margin_pct), min_margin_pct = "
                         "COALESCE($2, min_margin_pct), overhead_pct = COALESCE($3, overhead_pct), optimistic_hours_pct = "
                         "COALESCE($4, optimistic_hours_pct), optimistic_cost_pct = COALESCE($5, optimistic_cost_pct), "
                         "optimistic_rate_pct = COALESCE($6, optimistic_rate_pct), optimistic_delay_weeks = COALESCE($7, "
                         "optimistic_delay_weeks), pessimistic_hours_pct = COALESCE($8, pessimistic_hours_pct), "
                         "pessimistic_cost_pct = COALESCE($9, pessimistic_cost_pct), pessimistic_rate_pct = COALESCE($10, "
                         "pessimistic_rate_pct), pessimistic_delay_weeks = COALESCE($11, pessimistic_delay_weeks), updated_by "
                         "= $12, updated_at = now() WHERE id = 1",
                         *[f.get(k) for k in FIELDS], ana.context.user)
        except ana.SqlError:
            raise ana.Error("INVALID_PARAMETER", "valores fora do permitido (margem mínima ≤ alvo; "
                                                 "variações entre -90% e 500%)") from None
        if profile_costs:
            codes = [str(c).upper() for c in profile_costs]
            found = {r["code"] for r in ana.sql(
                "UPDATE projects.rate_profile r SET standard_cost = x.cost::numeric FROM unnest($1::text[], $2::text[]) AS x(code, cost) "
                "WHERE r.code = x.code RETURNING r.code", codes, [str(v) for v in profile_costs.values()])}
            missing = [c for c in codes if c not in found]
            if missing:
                raise ana.Error("PROFILE_NOT_FOUND", "perfil(is) inexistente(s): " + ", ".join(missing))
    pol = ana.sql_one("SELECT target_margin_pct, min_margin_pct, overhead_pct, optimistic_hours_pct, optimistic_cost_pct, "
                      "optimistic_rate_pct, optimistic_delay_weeks, pessimistic_hours_pct, pessimistic_cost_pct, "
                      "pessimistic_rate_pct, pessimistic_delay_weeks FROM projects.policy WHERE id = 1")
    if access.is_admin():
        ana.table([{"perfil": r["code"], "valor-hora": r["hourly_rate"], "custo padrão": r["standard_cost"] or "média das pessoas"}
                   # ana:lint-ok unbounded_select — rate profiles: small configuration table
                   for r in ana.sql("SELECT code, hourly_rate, standard_cost FROM projects.rate_profile ORDER BY code")],
                  title="Perfis")
    ana.table([{"parâmetro": k, "valor": pol[k]} for k in FIELDS], title="Política de projeção")
    return {k: pol[k] for k in FIELDS}
