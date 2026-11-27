# ana:description Cenários: projeção do caixa, das entregas e da margem nas próximas semanas, pelo que já está no ERP
# ana:exposed yes
# ana:read_only yes
# ana:command projecao
# ana:category Financeiro/Cenários
"""Spec 069 (T-069-02, RF-069-01, D1, D4, D8). The base projection: cash week by week with the lowest position and
its day, deliveries at risk, margin by item, line and customer, the delays used (measured) and how far the projection
of a week ago was from what happened. Runs as the person (their data scope) and read-only: nothing is ever saved. The
company's cash only for whoever may see the bank statement.

With `scenarios` (saved, combined) and/or `shocks` (not saved), the same projection is made again from the shocked
sources (T-069-03, RF-069-02) and set beside the base."""

import json

from ana_lib.scenario import effect, projection
from ana_lib.scenario import shocks as sh

SINGLES_MAX = 5         # up to this many shocks, each one is projected alone to name the cause of each effect

PARAMS = {"horizon_weeks": {"type": "int", "default": 26, "label": "semanas à frente (até 52)"},
          "scenarios": {"type": "list", "label": "cenários guardados a combinar (ids)"},
          "shocks": {"type": "list", "label": "choques avulsos [{kind, params}] (não são guardados)"}}


def combined(ids, extra):
    """The shocks of the scenarios (one's own or shared with a group of theirs) and the loose ones, checked again with
    this person's scope (what they point to may have changed, or be out of their reach: D8)."""
    ids = [int(i) for i in (ids or [])]
    rows = ana.sql("SELECT id, name, shocks FROM scenario.scenario WHERE id = ANY($1) "
                   "AND (owner = $2 OR shared_group IN (SELECT g FROM bpm.user_groups($2) AS g)) ORDER BY id",
                   ids, ana.context.user) if ids else []
    missing = sorted(set(ids) - {r["id"] for r in rows})
    if missing:
        raise ana.Error("SCENARIO_NOT_FOUND", f"cenário não encontrado ou não compartilhado: {', '.join(map(str, missing))}")
    all_shocks = []
    for r in rows:
        all_shocks += json.loads(r["shocks"]) if isinstance(r["shocks"], str) else r["shocks"]
    all_shocks += list(extra or [])
    return [r["name"] for r in rows], sh.validate(all_shocks)


def compare(base, scen, cash):
    """Scenario against the base: what the screen of comparison (T-069-05) starts from."""
    def margins(o, dim):
        return {r["key"]: r["margin"] for r in o["result"][dim]}

    out = {"margin_by_group": [], "deliveries_late": []}
    bg, sg = margins(base, "groups"), margins(scen, "groups")
    for k in sorted(set(bg) | set(sg), key=str):
        out["margin_by_group"].append({"group": k, "base": bg.get(k, 0), "scenario": sg.get(k, 0),
                                       "change": sg.get(k, 0) - bg.get(k, 0)})
    risk = {r["doc"]: r for r in base["deliveries_at_risk"]}
    out["deliveries_late"] = [r for r in scen["deliveries_at_risk"] if r["doc"] not in risk or risk[r["doc"]]["date"] != r["date"]]
    if cash:
        out["lowest"] = {"base": base["lowest"], "scenario": scen["lowest"],
                         "change": scen["lowest"]["balance"] - base["lowest"]["balance"]}
    return out


def main(horizon_weeks=26, scenarios=None, shocks=None):
    weeks = max(1, min(int(horizon_weeks), 52))
    names, checked = combined(scenarios, shocks) if (scenarios or shocks) else ([], None)
    cash = ana.can_run("finance.statement")
    g = projection.build(weeks, cash=cash)
    out = projection.weekly(g, cash=cash)
    if checked is not None:
        gs = sh.project(checked, weeks, cash=cash)
        out["scenario"] = {"names": names, "shocks": checked, **projection.weekly(gs, cash=cash)}
        out["compare"] = compare(out, out["scenario"], cash)
        singles = ({i: sh.project([s], weeks, cash=cash) for i, s in enumerate(checked)}
                   if 1 < len(checked) <= SINGLES_MAX else None)
        out["compare"].update(effect.explain(g, gs, checked, singles, cash=cash))
        ana.table([{"choque": s["label"]} for s in checked], title="Choques do cenário", empty="Sem choques: igual à base",
                  empty_good=True)
        c = out["compare"]
        if cash:
            ana.metrics([{"label": "Menor posição no cenário", "value": f"R$ {c['lowest']['scenario']['balance']:,.2f}",
                          "status": "bad" if c["lowest"]["scenario"]["balance"] < 0 else "ok"},
                         {"label": "Diferença para a base", "value": f"R$ {c['lowest']['change']:,.2f}"},
                         {"label": "Quando", "value": f"{c['lowest']['scenario']['date']:%d/%m/%Y}"}], title="Cenário")
        ana.table([{"linha": r["group"], "base": r["base"], "cenário": r["scenario"], "diferença": r["change"]}
                   for r in c["margin_by_group"]], title="Margem por linha: base × cenário", empty="Nenhum pedido em carteira",
                  empty_good=True)
        ana.table([{"efeito": e["text"]} for e in out["compare"]["effects"]], title="Caminho do efeito (o que mais pesa)",
                  empty="Nada mudou em relação à base", empty_good=True)
        for n in gs.notes:
            ana.log(f"cenário: {n}")
    names = {r["id"]: r["name"] for r in ana.sql(
        "SELECT id, name FROM base.party WHERE id = ANY($1)",
        sorted({d["party"] for d in out["delays"]} | {c["key"] for c in out["result"]["customers"]}))}
    codes = {r["id"]: r["code"] for r in ana.sql("SELECT id, code FROM base.product WHERE id = ANY($1)",
                                                 sorted({i["key"] for i in out["result"]["items"]}))}
    for d in out["delays"]:
        d["name"] = names.get(d["party"])
    if cash:
        out["backtest"] = projection.backtest()
        low = out["lowest"]
        ana.metrics([{"label": "Saldo hoje", "value": f"R$ {out['opening']:,.2f}"},
                     {"label": "Menor posição", "value": f"R$ {low['balance']:,.2f}", "status": "bad" if low["balance"] < 0 else "ok"},
                     {"label": "Quando", "value": f"{low['date']:%d/%m/%Y}"},
                     {"label": "Entregas em risco", "value": len(out["deliveries_at_risk"]),
                      "status": "warn" if out["deliveries_at_risk"] else "ok"},
                     {"label": "Erro da projeção de 7 dias atrás", "value": f"{out['backtest']['deviation_pct']}%"}],
                    title="Projeção base")
        ana.chart(type="line", title="Caixa no fim de cada semana", format="money",
                  x=[f"{w['week']:%d/%m}" for w in out["weeks"]], series=[{"name": "Saldo", "values": [w["close"] for w in out["weeks"]]}])
        ana.table([{"semana": f"{w['week']:%d/%m/%Y}", "entradas": w["in"], "saídas": -w["out"], "saldo": w["close"]}
                   for w in out["weeks"]], title="Caixa por semana")
    else:
        out["cash_hidden"] = "o caixa da empresa só aparece para quem consulta o extrato bancário"
        ana.metrics([{"label": "Entregas em risco", "value": len(out["deliveries_at_risk"]),
                      "status": "warn" if out["deliveries_at_risk"] else "ok"}], title="Projeção base")
    ana.table([{"cliente": names.get(c["key"], c["key"]), "receita": c["revenue"], "custo": c["cost"], "margem": c["margin"]}
               for c in out["result"]["customers"]], title="Margem por cliente", empty="Nenhum pedido em carteira", empty_good=True)
    ana.table([{"item": codes.get(i["key"], i["key"]), "receita": i["revenue"], "custo": i["cost"], "margem": i["margin"]}
               for i in out["result"]["items"]], title="Margem por item", empty="Nenhum pedido em carteira", empty_good=True)
    ana.table([{"pedido": r["doc"], "prometido": r["promised"], "previsto": r["date"] or "sem cobertura no horizonte"}
               for r in out["deliveries_at_risk"]], title="Entregas em risco", empty="Nenhuma entrega em risco", empty_good=True)
    ana.table([{"tipo": d["kind"], "parte": d["name"], "dias": d["days"], "de onde vem": d["source"]} for d in out["delays"]],
              title="Atrasos usados (medidos)", empty="Sem atrasos a considerar", empty_good=True)
    for n in g.notes:
        ana.log(n)
    return out
