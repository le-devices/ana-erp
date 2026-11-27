# ana:description Cenários: tira um choque de um cenário seu
# ana:exposed yes
# ana:category Financeiro/Cenários
"""Spec 069 (T-069-05). `index` counts from 1, as the screen shows the shocks."""

import json

PARAMS = {"id": {"type": "int", "required": True, "label": "cenário"},
          "index": {"type": "int", "required": True, "label": "choque (nº)"}}


def main(id, index):
    row = ana.sql_one("SELECT shocks FROM scenario.scenario WHERE id = $1 AND owner = $2 FOR UPDATE", id, ana.context.user)
    if not row:
        raise ana.Error("SCENARIO_NOT_FOUND", "cenário não encontrado entre os seus (só quem criou altera)")
    current = json.loads(row["shocks"]) if isinstance(row["shocks"], str) else row["shocks"]
    if not 1 <= index <= len(current):
        raise ana.Error("SCENARIO_SHOCK", f"o cenário tem {len(current)} choque(s)")
    del current[index - 1]
    ana.sql_exec("UPDATE scenario.scenario SET shocks = $2::jsonb, version = version + 1, updated_at = now() WHERE id = $1",
                 id, json.dumps(current, ensure_ascii=False))
    return {"id": id, "shocks": len(current)}
