# ana:description Cenários: recalcula um cenário vigiado, guarda o resumo e avisa quando o caixa piora além do limite
# ana:category Financeiro/Cenários
"""Spec 069 (T-069-08, RF-069-06, D7, CA-069-06). Run by the scheduler as the scenario's owner (their data scope).
The summary of the run is kept on the scenario (one write: spec 063) and is the metric of the rules of spec 051
("cenario_<id>_menor_caixa", "cenario_<id>_semanas_ate_negativo"). A warning goes to the owner and the group when
the lowest cash position passes below the limit, or reaches it sooner than in the last run — with the comparison."""

import datetime
import json
from decimal import Decimal

from ana_lib.scenario import compare as cmp_lib

PARAMS = {"id": {"type": "int", "required": True, "label": "cenário"}}
WEEKS = 26


def money(v):
    return f"R$ {Decimal(v):,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


def summary(base, scen, cmp):
    neg = next((i + 1 for i, w in enumerate(scen["weeks"]) if Decimal(w["close"]) < 0), None)
    return {"lowest": str(scen["lowest"]["balance"]), "lowest_date": scen["lowest"]["date"].isoformat(),
            "base_lowest": str(base["lowest"]["balance"]), "margin": str(cmp["margin"]["scenario"]),
            "deliveries_late": len(cmp["deliveries_late"]), **({"weeks_to_negative": neg} if neg else {}),
            "at": datetime.datetime.now().isoformat(timespec="seconds")}


def warning(name, limit, now, before):
    """The text of the warning, or None when nothing got worse."""
    low = Decimal(now["lowest"])
    if low >= limit:
        return None
    neg, prev_neg = now.get("weeks_to_negative"), (before or {}).get("weeks_to_negative")
    if before and Decimal(before["lowest"]) < limit and (prev_neg is None or neg is None or neg >= prev_neg):
        return None                                   # already below and not sooner: warned before
    if neg:
        tail = f" — antes eram {prev_neg}" if prev_neg else ""
        return f"No cenário “{name}”, o caixa fica negativo em {neg} semana(s){tail}."
    when = datetime.date.fromisoformat(now["lowest_date"])
    tail = f" — antes {money(before['lowest'])}" if before else f" — na base {money(now['base_lowest'])}"
    return (f"No cenário “{name}”, a menor posição de caixa fica em {money(low)} em {when:%d/%m/%Y}, abaixo do limite de "
            f"{money(limit)}{tail}.")


def main(id):
    s = ana.sql_one("SELECT id, name, owner, shared_group, watch_limit, last_result FROM scenario.scenario "
                    "WHERE id = $1 AND owner = $2", id, ana.context.user)
    if not s:
        raise ana.Error("SCENARIO_NOT_FOUND", "cenário não encontrado entre os seus")
    if not ana.can_run("finance.statement"):
        raise ana.Error("SCENARIO_WATCH_CASH", "vigiar um cenário pede acesso ao extrato bancário (o caixa da empresa)")
    run = cmp_lib.run(WEEKS, [id], None, cash=True)
    now = summary(run["base"], run["scenario"], run["compare"])
    before = json.loads(s["last_result"]) if isinstance(s["last_result"], str) else s["last_result"]
    text = warning(s["name"], Decimal(s["watch_limit"]), now, before)
    ana.sql_exec("UPDATE scenario.scenario SET last_result = $2::jsonb, last_run_at = now() WHERE id = $1",
                 id, json.dumps(now))
    if text:
        ana.sql("SELECT automation.notify($1, $2, $3)", s["owner"], s["shared_group"], text)
        ana.log(text)
    return {**now, "warned": text}
