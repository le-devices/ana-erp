# ana:description Planejamento de necessidades: explode estruturas e propõe ordens de produção e compras
# ana:exposed yes
# ana:command mrp
# ana:category Produção/Planejamento
"""RF-014-05, RNF-014-01/02, CA-014-01.

Low-level code of every item by a recursive query; then level by level, in batch:
gross requirements (open sales orders, net forecast, components of firm orders not yet
issued, and the components of what was suggested at the levels above) against on-hand plus
scheduled receipts (open production orders, open purchase orders and purchase requests) per
week; below the safety stock → a lot (minimum, multiple) is suggested, started lead time
before it is needed; a "make" suggestion explodes into its components for the next levels.

Idempotent per scenario: the open suggestions of the scenario are replaced; approved ones and
firm orders are never touched. Long runs: execute asynchronously or schedule it (spec 018)."""

import json

from ana_lib.production import mrp

PARAMS = {
    "scenario": {"type": "str", "default": "principal", "label": "cenário"},
    "horizon_weeks": {"type": "int", "default": 12, "label": "horizonte (semanas)"},
}


def main(scenario="principal", horizon_weeks=12):
    horizon_weeks = max(1, min(int(horizon_weeks), 104))
    run = ana.sql_value("INSERT INTO production.planning_run (scenario, horizon_weeks, created_by) VALUES ($1, $2, $3) RETURNING id",
                        scenario, horizon_weeks, ana.context.user)
    suggestions = mrp.compute(horizon_weeks)      # the calculation (production.mrp, spec 069): here it is recorded

    # Replace the open suggestions of the scenario (approved ones stay).
    ana.sql_exec("UPDATE production.suggestion SET status = 'discarded' WHERE scenario = $1 AND status = 'open'", scenario)
    if suggestions:
        ana.sql_batch("INSERT INTO production.suggestion (run_id, scenario, kind, product_id, quantity, start_date, need_date, origin) "
                      "VALUES ($1, $2, $3, $4, $5, $6, $7, $8::text::jsonb)",
                      [[run, scenario, k, i, q, s, n, ana_json(o)] for k, i, q, s, n, o, _lead in suggestions])
    ana.sql_exec("UPDATE production.planning_run SET status = 'done', suggestions = $2, finished_at = now() WHERE id = $1",
                 run, len(suggestions))
    codes = {r["id"]: r["code"] for r in ana.sql("SELECT id, code FROM base.product WHERE id = ANY($1)",
                                                 sorted({s[1] for s in suggestions}))}
    ana.metrics([{"label": "Sugestões", "value": len(suggestions)},
                 {"label": "Fabricar", "value": sum(1 for s in suggestions if s[0] == "make")},
                 {"label": "Comprar", "value": sum(1 for s in suggestions if s[0] == "buy")},
                 {"label": "Atrasadas", "value": sum(1 for s in suggestions if "atrasada" in s[5]),
                  "status": "bad" if any("atrasada" in s[5] for s in suggestions) else "ok"}])
    ana.table([{"ação": "fabricar" if k == "make" else "comprar", "item": codes[i], "quantidade": q, "início": s,
                "necessário em": n, "origem": "; ".join(o).replace("#", "")}
               for k, i, q, s, n, o in suggestions[:500]], title=f"Sugestões — cenário {scenario}")
    if suggestions:
        ana.actions([{"label": "Aprovar todas", "program": "production.approve_suggestions", "params": {"scenario": scenario},
                      "style": "primary", "confirm": f"Gerar {len(suggestions)} ordem(ns) e solicitação(ões)?"}],
                    title="Próximo passo")
    return {"run": run, "suggestions": [{"kind": k, "product": codes[i], "quantity": q, "start": s, "need": n}
                                        for k, i, q, s, n, _ in suggestions]}


def ana_json(v):
    return json.dumps(v, ensure_ascii=False)
