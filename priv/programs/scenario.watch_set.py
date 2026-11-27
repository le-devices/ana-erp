# ana:description Cenários: vigia um cenário seu — recalcula de tempos em tempos e avisa quando o caixa fica abaixo do limite
# ana:exposed yes
# ana:category Financeiro/Cenários
"""Spec 069 (T-069-08, D7). Keeps the scheduler job "scenario.vigia_<id>" (as the owner: their scope) and the limit.
Without a schedule, the watch stops."""

PARAMS = {
    "id": {"type": "int", "required": True, "label": "cenário"},
    "cron": {"type": "str", "label": "quando recalcular", "default": "0 7 * * *",
             "choices": [["0 7 * * *", "todo dia às 7h"], ["0 7 * * 1", "toda segunda às 7h"], ["", "parar de vigiar"]]},
    "limit": {"type": "decimal", "default": 0, "label": "avisar quando o caixa ficar abaixo de (R$)"},
}


def main(id, cron="0 7 * * *", limit=0):
    cron = (cron or "").strip() or None
    if cron and not ana.can_run("finance.statement"):
        raise ana.Error("SCENARIO_WATCH_CASH", "vigiar um cenário pede acesso ao extrato bancário (o caixa da empresa)")
    name = ana.sql_value("UPDATE scenario.scenario SET watch_cron = $2, watch_limit = $3, "
                         "  last_result = CASE WHEN $2::text IS NULL THEN NULL ELSE last_result END "
                         "WHERE id = $1 AND owner = $4 RETURNING name", id, cron, limit, ana.context.user)
    if name is None:
        raise ana.Error("SCENARIO_NOT_FOUND", "cenário não encontrado entre os seus (só quem criou vigia)")
    job = ana.schedule_job(f"scenario.vigia_{id}", "scenario.watch", {"id": id}, cron=cron, active=bool(cron),
                           description=f"Vigia o cenário {name}")
    ana.log(f"cenário {name}: " + (f"vigiado ({cron}), aviso abaixo de R$ {limit}" if cron else "não é mais vigiado"))
    return {"id": id, "cron": cron, "limit": limit, "job": job.get("job")}
