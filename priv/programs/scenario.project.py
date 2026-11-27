# ana:description Cenários: projeção do caixa, das entregas e da margem nas próximas semanas, pelo que já está no ERP
# ana:exposed yes
# ana:read_only yes
# ana:command projecao
# ana:category Financeiro/Cenários
"""Spec 069 (T-069-02, RF-069-01, D1, D4, D8). The base projection: cash week by week with the lowest position and
its day, deliveries at risk, margin by item, line and customer, the delays used (measured) and how far the projection
of a week ago was from what happened. Runs as the person (their data scope) and read-only: nothing is ever saved. The
company's cash only for whoever may see the bank statement."""

from ana_lib.scenario import projection

PARAMS = {"horizon_weeks": {"type": "int", "default": 26, "label": "semanas à frente (até 52)"}}


def main(horizon_weeks=26):
    weeks = max(1, min(int(horizon_weeks), 52))
    g = projection.build(weeks)
    cash = ana.can_run("finance.statement")
    out = projection.weekly(g, cash=cash)
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
