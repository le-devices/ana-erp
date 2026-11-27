# ana:description Cenários "e se…": crie, combine e compare com a base — caixa, margem, entregas, o que mais pesa e o que fazer
# ana:exposed yes
# ana:read_only yes
# ana:command cenarios
# ana:category Financeiro/Cenários
"""Spec 069 (T-069-05, RF-069-04, D5). The scenarios screen: the person's scenarios (and the ones shared with a group
of theirs); a scenario — or several combined — against the base, side by side: cash week by week with the lowest
position and its day, working capital, margin by line, deliveries that get later; what weighs most (by shock and by
item); the path of each effect; what to do, each suggestion opening its routine. The shocks are added and removed in
place, with the catalog's forms. Reads only: saving goes through scenario.save / add_shock / drop_shock."""

import json

from ana_lib.scenario import compare as cmp_lib
from ana_lib.scenario import shocks as sh

WB = "scenario.workbench"
VIEWS = [("list", "Cenários"), ("compare", "Comparar com a base"), ("kinds", "Choques disponíveis")]
PARAMS = {
    "view": {"type": "str", "default": "list", "label": "visão", "choices": [[v, label] for v, label in VIEWS]},
    "scenarios": {"type": "list", "label": "cenários (números) — mais de um: combinados"},
    "horizon_weeks": {"type": "int", "default": 26, "label": "semanas à frente (até 52)"},
}
FIELD = {
    "currency": lambda p: {"type": "str", "choices": [["USD", "Dólar"], ["EUR", "Euro"]]},
    "percent": lambda p: {"type": "decimal"},
    "date": lambda p: {"type": "date"},
    "days": lambda p: {"type": "int"},
    "supplier": lambda p: {"type": "int", "lookup": {"program": "supply.lookup", "params": {"kind": "suppliers"}}},
    "customer": lambda p: {"type": "int", "lookup": {"program": "sales.lookup", "params": {"kind": "customers"}}},
    "item": lambda p: {"type": "str", "lookup": {"program": "supply.lookup", "params": {"kind": "products"}}},
    "group": lambda p: {"type": "str"},
    "resource": lambda p: {"type": "str", "lookup": {"program": "production.lookup", "params": {"kind": "resources"}}},
    "tax_rule": lambda p: {"type": "int"},
    "value_name": lambda p: {"type": "str"},
    "value": lambda p: {"type": "str"},
    "choice": lambda p: {"type": "str", "choices": p.get("choices", [])},
}


def visible():
    return ana.sql("SELECT s.id, s.name, s.owner, s.shared_group, s.shocks, s.updated_at FROM scenario.scenario s "
                   "WHERE s.owner = $1 OR s.shared_group IN (SELECT g FROM bpm.user_groups($1) AS g) "
                   "ORDER BY s.updated_at DESC LIMIT 200", ana.context.user)


def shocks_of(r):
    return json.loads(r["shocks"]) if isinstance(r["shocks"], str) else (r["shocks"] or [])


def open_compare(ids, label="Comparar com a base"):
    return {"label": label, "program": WB, "params": {"view": "compare", "scenarios": [int(i) for i in ids]}, "open": True}


def main(view="list", scenarios=None, horizon_weeks=26):
    ids = [int(i) for i in (scenarios or [])]
    ana.tabs([{"label": label, "program": WB, "params": {"view": v, **({"scenarios": ids} if v == "compare" and ids else {})},
               "open": True} for v, label in VIEWS], current=view)
    if view == "kinds":
        return kinds()
    if view == "compare" and ids:
        return compare(ids, max(1, min(int(horizon_weeks), 52)))
    return listing(view == "compare")


def listing(choosing):
    rows = visible()
    new = {"label": "Novo cenário", "program": "scenario.save", "style": "primary",
           "ask": {"name": {"type": "str", "label": "nome", "required": True},
                   "group": {"type": "str", "label": "compartilhar com o grupo (vazio = só você)"}}}
    ana.actions([new, {"label": "Projeção base", "program": "scenario.project", "params": {}, "open": True}],
                title="Escolha um cenário para comparar com a base" if choosing else None)
    ana.table([{"nº": r["id"], "cenário": r["name"], "choques": len(shocks_of(r)),
                "de": "você" if r["owner"] == ana.context.user else r["owner"], "grupo": r["shared_group"] or "—",
                "_open": open_compare([r["id"]]),
                "_actions": [open_compare([r["id"]], "Comparar")] + ([
                    {"label": "Apagar", "program": "scenario.remove", "params": {"id": r["id"]}, "style": "danger",
                     "confirm": f"Apagar o cenário {r['name']}? Só a definição é apagada; a projeção nunca gravou nada."}]
                    if r["owner"] == ana.context.user else [])}
               for r in rows], title="Cenários",
              empty="Nenhum cenário ainda: um cenário reúne choques (dólar, atraso de fornecedor, volume…) para comparar "
                    "com a base.",
              empty_action={"label": "Criar o primeiro cenário", "program": "scenario.save"})
    return {"scenarios": [{"id": r["id"], "name": r["name"], "owner": r["owner"], "group": r["shared_group"]} for r in rows]}


def kinds():
    cat = sh.catalog()
    ana.table([{"choque": k["name"], "o que muda": k["description"],
                "parâmetros": ", ".join(p["label"] for p in k["params"])} for k in cat], title="Choques disponíveis",
              empty="Nenhum tipo de choque ativo", empty_good=True)
    return {"kinds": [k["code"] for k in cat]}


def compare(ids, weeks):
    cash = ana.can_run("finance.statement")
    run = cmp_lib.run(weeks, ids, None, cash=cash)
    base, scen, c = run["base"], run["scenario"], run["compare"]
    names = " + ".join(scen["names"])
    rows = {r["id"]: r for r in visible()}
    mine = len(ids) == 1 and rows.get(ids[0], {}).get("owner") == ana.context.user

    items = [{"label": "Margem no cenário", "value": f"R$ {c['margin']['scenario']:,.2f}",
              "hint": f"{'+' if c['margin']['change'] >= 0 else ''}R$ {c['margin']['change']:,.2f} sobre a base",
              "status": "bad" if c["margin"]["change"] < 0 else "ok"},
             {"label": "Entregas que atrasam", "value": len(c["deliveries_late"]),
              "status": "warn" if c["deliveries_late"] else "ok"}]
    if cash:
        low = c["lowest"]
        items = [{"label": "Menor posição de caixa", "value": f"R$ {low['scenario']['balance']:,.2f}",
                  "hint": f"em {low['scenario']['date']:%d/%m/%Y}; na base R$ {low['base']['balance']:,.2f} "
                          f"em {low['base']['date']:%d/%m/%Y}",
                  "status": "bad" if low["scenario"]["balance"] < 0 else "warn" if low["change"] < 0 else "ok"},
                 {"label": "Capital de giro a mais", "value": f"R$ {c['working_capital']['change']:,.2f}",
                  "status": "warn" if c["working_capital"]["change"] > 0 else "ok"}] + items
    ana.metrics(items, title=f"{names} × base")
    if cash:
        ana.chart(type="line", title="Caixa no fim de cada semana: base × cenário", format="money",
                  x=[f"{w['week']:%d/%m}" for w in base["weeks"]],
                  series=[{"name": "Base", "values": [w["close"] for w in base["weeks"]]},
                          {"name": names, "values": [w["close"] for w in scen["weeks"]]}])
    else:
        ana.log("o caixa da empresa só aparece para quem consulta o extrato bancário")

    w = c["weights"]
    ana.table([{"choque": r["shock"], "na margem": r["margin"], "parte da margem": f"{r['margin_share']}%" if r["margin_share"] is not None else "—",
                **({"no caixa": r["cash"], "parte do caixa": f"{r['cash_share']}%" if r["cash_share"] is not None else "—"} if cash else {})}
               for r in w["by_shock"]], title="O que mais pesa: por choque",
              empty="Com mais de 5 choques, o peso de cada um não é separado" if len(scen["shocks"]) > 1 else
                    "Sem choques: o cenário é igual à base", empty_good=True)
    ana.table([{"item": r["code"], "mudança na margem": r["change"], "parte do efeito": f"{r['share']}%"} for r in w["by_item"]],
              title="O que mais pesa: por item", empty="A margem dos itens não muda", empty_good=True)
    ana.table([{"linha": r["group"], "base": r["base"], "cenário": r["scenario"], "diferença": r["change"]}
               for r in c["margin_by_group"]], title="Margem por linha", empty="Nenhum pedido em carteira", empty_good=True)
    ana.table([{"pedido": r["doc"], "prometido": r["promised"], "previsto": r["date"] or "sem cobertura no horizonte"}
               for r in c["deliveries_late"]], title="Entregas que atrasam no cenário", empty="Nenhuma entrega atrasa",
              empty_good=True)
    ana.table([{"efeito": e["text"]} for e in c["effects"]], title="Caminho do efeito",
              empty="Nada mudou em relação à base", empty_good=True)
    if c["suggestions"]:
        ana.actions(c["suggestions"], title="O que fazer")

    ana.table([{"nº": n, "choque": s["label"],
                "_actions": [{"label": "Tirar", "program": "scenario.drop_shock", "params": {"id": ids[0], "index": n},
                              "confirm": f"Tirar o choque “{s['label']}” do cenário?"}] if mine else []}
               for n, s in enumerate(scen["shocks"], 1)], title="Choques", empty="Sem choques: igual à base",
              empty_good=not mine,
              empty_action={"label": "Ver os choques disponíveis", "program": WB, "params": {"view": "kinds"}} if mine else None)
    if mine:
        ana.actions([{"label": k["name"], "program": "scenario.add_shock", "params": {"id": ids[0], "kind": k["code"]},
                      "ask": {p["name"]: {**FIELD[p["type"]](p), "label": p["label"], **({"required": True} if p.get("required") else {})}
                              for p in k["params"]}}
                     for k in sh.catalog()], title="Incluir um choque")
    others = [r for i, r in rows.items() if i not in ids]
    if others:
        ana.table([{"cenário": r["name"], "choques": len(shocks_of(r)),
                    "_actions": [open_compare(ids + [r["id"]], "Combinar")]} for r in others[:20]],
                  title="Combinar com outro cenário")
    for n in run["scenario_graph"].notes:
        ana.log(f"cenário: {n}")
    return {"names": scen["names"], "shocks": scen["shocks"], "compare": c}
