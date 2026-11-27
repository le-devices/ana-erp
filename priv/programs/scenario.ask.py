# ana:description Cenários pelo assistente: "e se…?" vira um cenário — primeiro as premissas entendidas, para conferir; confirmado, o efeito em relação à base
# ana:exposed yes
# ana:category Financeiro/Cenários
"""Spec 069 (T-069-07, RF-069-05, D6, CA-069-04). The assistant (spec 052) turns the question into shocks of the
catalog — nothing outside it — and calls this routine. Because it saves the scenario, the assistant only rehearses
it: the rehearsal shows the premises it understood (each shock as a sentence, the measured delays it will use, the
horizon) and calculates nothing. Only the person's "Confirmar" calculates, saves the scenario (to reopen in the
scenarios screen) and shows the effect. Everything with the permissions and the data scope of who asks: a shock on
what they cannot see is refused."""

import datetime
import json

from ana_lib.scenario import compare as cmp_lib
from ana_lib.scenario import projection
from ana_lib.scenario import shocks as sh

WEEKS = 26
PARAMS = {
    "question": {"type": "str", "required": True, "label": "a pergunta, como a pessoa fez"},
    "shocks": {"type": "list", "required": True, "label": (
        "choques [{kind, params}] só destes tipos: currency{currency: USD|EUR, pct, from?}; purchase_price{item|group, "
        "pct, from?}; supplier_delay{supplier: id, days}; supplier_stops{supplier: id, from?}; customer_delay{customer: id, "
        "days}; customer_stops{customer: id, from?}; payment_terms{side: receive|pay, days}; sales_volume{item|group|"
        "customer, pct}; capacity{resource, pct, from?, until}; tax_rule{rule: id de rascunho, from?}; "
        "company_value{name, value, from?}. pct em %, datas AAAA-MM-DD, item pelo código, partes pelo id")},
}


def premises(checked):
    """What will be assumed: the shocks, and the measured delays of the parties they touch."""
    delays = projection.Delays(datetime.date.today())
    out = [{"premissa": s["label"], "de onde vem": "da pergunta"} for s in checked]
    for s in checked:
        p = s["params"]
        for key, kind, who in (("supplier", "supplier", "fornecedor"), ("customer", "receivable", "cliente")):
            if key in p:
                days, source = delays.of(kind, p[key])
                out.append({"premissa": f"atraso que o {who} já tem: {days} dias", "de onde vem": source})
    out.append({"premissa": f"horizonte de {WEEKS} semanas, a partir de hoje", "de onde vem": "padrão da projeção"})
    return out


def main(question, shocks):
    checked = sh.validate(shocks)
    if not checked:
        raise ana.Error("SCENARIO_SHOCK", "a pergunta não virou nenhum choque da lista: reformule com o que muda")
    name = ("Pergunta: " + " ".join(question.split()))[:100]
    taken = ana.sql_value("SELECT count(*) FROM scenario.scenario WHERE owner = $1 AND name LIKE $2", ana.context.user,
                          name + "%")
    if taken:
        name = f"{name[:90]} ({taken + 1})"

    sid = ana.sql_value("INSERT INTO scenario.scenario (name, description, owner, shocks) VALUES ($1, $2, $3, $4::jsonb) "
                        "RETURNING id", name, question, ana.context.user,
                        json.dumps([{"kind": s["kind"], "params": s["params"]} for s in checked], ensure_ascii=False))
    assumed = premises(checked)
    ana.table(assumed, title="Premissas entendidas — confira antes de calcular")
    if ana.context.rehearsal:
        return {"premises": [a["premissa"] for a in assumed],
                "next": "confirme na tela para calcular e guardar o cenário; nada foi calculado nem guardado ainda"}
    cash = ana.can_run("finance.import_statement")
    run = cmp_lib.run(WEEKS, [sid], None, cash=cash)
    c = run["compare"]
    items = [{"label": "Margem", "value": f"R$ {c['margin']['change']:,.2f}", "hint": "diferença para a base",
              "status": "bad" if c["margin"]["change"] < 0 else "ok"},
             {"label": "Entregas que atrasam", "value": len(c["deliveries_late"])}]
    if cash:
        items.insert(0, {"label": "Menor posição de caixa", "value": f"R$ {c['lowest']['scenario']['balance']:,.2f}",
                         "hint": f"em {c['lowest']['scenario']['date']:%d/%m/%Y}; diferença para a base "
                                 f"R$ {c['lowest']['change']:,.2f}",
                         "status": "bad" if c["lowest"]["scenario"]["balance"] < 0 else "ok"})
    ana.metrics(items, title=name)
    ana.table([{"efeito": e["text"]} for e in c["effects"]], title="Caminho do efeito", empty="Nada mudou em relação à base",
              empty_good=True)
    ana.actions([{"label": "Abrir na tela de cenários", "program": "scenario.workbench",
                  "params": {"view": "compare", "scenarios": [sid]}, "open": True}] + c["suggestions"], title="O que fazer")
    return {"id": sid, "name": name, "premises": [a["premissa"] for a in assumed],
            "lowest": c.get("lowest"), "margin": c["margin"], "deliveries_late": c["deliveries_late"],
            "effects": [e["text"] for e in c["effects"][:5]]}
