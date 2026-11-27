# ana:description Cenários: apaga um cenário guardado (só quem o criou)
# ana:exposed yes
# ana:category Financeiro/Cenários
"""Spec 069 (T-069-03). Removing a scenario removes only its definition: a projection never wrote anything else."""

PARAMS = {"id": {"type": "int", "required": True, "label": "cenário"}}


def main(id):
    name = ana.sql_value("DELETE FROM scenario.scenario WHERE id = $1 AND owner = $2 RETURNING name", id, ana.context.user)
    if name is None:
        raise ana.Error("SCENARIO_NOT_FOUND", "cenário não encontrado entre os seus (só quem criou apaga)")
    ana.schedule_job(f"scenario.vigia_{id}", "scenario.watch", {"id": id}, cron=None, active=False)   # a watch stops with it
    ana.log(f"cenário {name} apagado")
    return {"removed": id, "name": name}
