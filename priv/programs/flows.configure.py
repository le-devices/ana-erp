# ana:description Configura as esteiras: ligar, robô responsável e, por etapa, automática ou manual com condições
# ana:command esteira_config
# ana:role admin
# ana:category Processos/Esteiras
"""RF-030-01, RF-030-02 (P13: the catalog is the product's; the owner only chooses). Without an
action, shows the flow. Conditions are restricted rules over the document's facts (e.g. total ≤ 5000;
criteria and exceptions in flows.step_condition): an automatic step whose condition fails waits for a person."""

import json

from ana_lib.flows import common
from ana_lib.util import conditions

PARAMS = {
    "flow": {"type": "str", "required": True, "default": "sales", "label": "esteira", "order": 1,
             "lookup": {"program": "flows.lookup", "params": {"kind": "flows"}}},
    "action": {"type": "str", "label": "ação", "order": 2,
               "choices": [["activate", "Ligar"], ["deactivate", "Desligar"], ["include_open", "Incluir documentos em aberto"],
                           ["run_as", "Robô responsável"], ["mode", "Modo da etapa"], ["condition", "Condição da etapa"],
                           ["clear_condition", "Limpar condição"]]},
    "step": {"type": "int", "label": "etapa (nº)", "order": 3},
    "mode": {"type": "str", "label": "modo", "order": 4, "choices": [["auto", "Automática"], ["manual", "Manual"]]},
    "field": {"type": "str", "label": "campo do documento", "order": 5},
    "op": {"type": "str", "label": "operador", "order": 6,
           "choices": [["<=", "até (≤)"], ["<", "menor que"], [">=", "a partir de (≥)"], [">", "maior que"], ["=", "igual a"],
                       ["!=", "diferente de"]]},
    "value": {"type": "str", "label": "valor", "order": 7},
    "user": {"type": "str", "label": "usuário robô", "order": 8},
}


def main(flow="sales", action=None, step=None, mode=None, field=None, op=None, value=None, user=None):
    d = common.definition(flow)
    who = ana.context.user
    if action == "activate" or action == "deactivate":
        ana.sql_exec("UPDATE flow.definition SET active = $2, updated_by = $3, updated_at = now() WHERE code = $1",
                     flow, action == "activate", who)
        ana.log(f"esteira {flow} {'ligada' if action == 'activate' else 'desligada'}")
    elif action == "include_open":
        n = ana.sql_value("SELECT flow.include_open($1)", flow)
        ana.log(f"{n} documento(s) em aberto entraram na esteira")
    elif action == "run_as":
        u = ana.sql_one("SELECT username, kind, active FROM ana_system.app_user WHERE username = $1", (user or "").strip())
        if not u or not u["active"]:
            raise ana.Error("USER_NOT_FOUND", "usuário inexistente ou inativo")
        ana.sql_exec("UPDATE flow.definition SET run_as = $2, updated_by = $3, updated_at = now() WHERE code = $1", flow, u["username"], who)
    elif action in ("mode", "condition", "clear_condition"):
        s = ana.sql_one("SELECT seq, mode, condition FROM flow.step WHERE flow_code = $1 AND seq = $2", flow, step)
        if not s:
            raise ana.Error("STEP_NOT_FOUND", f"etapa {step} não existe nesta esteira")
        if s["mode"] == "wait":
            raise ana.Error("INVALID_OPERATION", "esta etapa aguarda um evento externo: não tem modo nem condição")
        if action == "mode":
            if mode not in ("auto", "manual"):
                raise ana.Error("INVALID_PARAMETER", "modo deve ser automática ou manual")
            ana.sql_exec("UPDATE flow.step SET mode = $3 WHERE flow_code = $1 AND seq = $2", flow, step, mode)
        elif action == "clear_condition":
            ana.sql_exec("UPDATE flow.step SET condition = '[]' WHERE flow_code = $1 AND seq = $2", flow, step)
        else:
            if not field or op not in dict(common.OPS) or value is None:
                raise ana.Error("INVALID_PARAMETER", "informe campo, operador e valor")
            # One more line in every criterion (the whole rule stays as it was otherwise).
            n = conditions.normalize(s["condition"])
            line = {"field": field.strip(), "op": op, "value": value.strip()}
            n["any"] = [c + [line] for c in n["any"]] or [[line]]
            ana.sql_exec("UPDATE flow.step SET condition = $3::text::jsonb WHERE flow_code = $1 AND seq = $2", flow, step,
                         json.dumps(conditions.compact(n)))
        ana.sql_exec("UPDATE flow.definition SET updated_by = $2, updated_at = now() WHERE code = $1", flow, who)
    elif action:
        raise ana.Error("INVALID_PARAMETER", f"ação desconhecida: {action}")

    d = common.definition(flow)
    steps = ana.sql("SELECT seq, code, name, program, mode, condition FROM flow.step WHERE flow_code = $1 ORDER BY seq", flow)
    ana.metrics([{"label": "Situação", "value": "ligada" if d["active"] else "desligada", "status": "ok" if d["active"] else "warn"},
                 {"label": "Robô responsável", "value": d["run_as"]},
                 {"label": "Etapas automáticas", "value": sum(1 for s in steps if s["mode"] == "auto")}],
                title=f"{d['name']}: {d['description']}")
    ana.actions(([{"label": "Desligar", "program": "flows.configure", "params": {"flow": flow, "action": "deactivate"},
                   "confirm": "Documentos novos deixam de entrar na esteira. Continuar?"}] if d["active"] else
                 [{"label": "Ligar", "program": "flows.configure", "params": {"flow": flow, "action": "activate"}, "style": "primary"}])
                + [{"label": "Incluir documentos em aberto", "program": "flows.configure", "params": {"flow": flow, "action": "include_open"},
                    "confirm": f"Colocar na esteira todos os {d['document']}s ainda em aberto?"},
                   {"label": "Robô responsável", "program": "flows.configure", "params": {"flow": flow, "action": "run_as"},
                    "ask": {"user": {"type": "str", "required": True, "label": "usuário (pessoa ou robô)"}}},
                   {"label": "Ver a esteira", "program": "flows.board", "params": {"flow": flow}, "open": True}], title="Esteira")
    rows = []
    for s in steps:
        acts = []
        if s["mode"] != "wait":
            other = "manual" if s["mode"] == "auto" else "auto"
            acts.append({"label": f"Tornar {common.MODE[other]}", "program": "flows.configure",
                         "params": {"flow": flow, "action": "mode", "step": s["seq"], "mode": other}})
            # RF-020-13/14: criteria, exceptions and the simulation of the documents it takes, on its own screen.
            acts.append({"label": "Condição…", "program": "flows.step_condition", "params": {"flow": flow, "step": s["seq"], "condition": s["condition"]},
                         "open": True})
            if s["condition"]:
                acts.append({"label": "Limpar condição", "program": "flows.configure",
                             "params": {"flow": flow, "action": "clear_condition", "step": s["seq"]}})
        rows.append({"etapa": f"{s['seq']}. {s['name']}", "rotina": s["program"] or "—", "modo": common.MODE[s["mode"]],
                     "condição para ser automática": common.condition_text(s["condition"], flow) if s["mode"] == "auto" else "—",
                     "_actions": acts})
    ana.table(rows, title="Etapas")
    return {"flow": flow, "active": d["active"], "run_as": d["run_as"],
            "steps": [{"seq": s["seq"], "code": s["code"], "mode": s["mode"], "condition": s["condition"]} for s in steps]}
