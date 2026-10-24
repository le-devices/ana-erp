# ana:description Etapas do processo de um documento: o que já foi feito, onde está e o que falta
# ana:exposed yes
# ana:command etapas
# ana:category Processos/Esteiras
"""RF-020-11, CA-020-07. The stages of a process (sale, purchase, field service, production) for one
document, computed from the document's own facts — the same rules the esteiras use to know that a stage
happened — so it works whether the esteira is on or off. The current stage offers "Fazer agora" with the
document filled in."""

from ana_lib.docs.common import link as doc_link
from ana_lib.flows import common

DOC_KIND = {"sales": "order", "purchase": "purchase_request", "field": "service_order", "production": "work_order"}

PARAMS = {
    "flow": {"type": "str", "required": True, "default": "sales", "label": "processo", "order": 1,
             "lookup": {"program": "flows.lookup", "params": {"kind": "flows"}}},
    "document": {"type": "str", "required": True, "label": "documento (nº)", "order": 2},
}


def main(flow="sales", document=None):
    d = common.definition(flow)
    key = str(document).strip()
    facts = ana.sql_one(ana.sql_value("SELECT facts_sql FROM flow.definition WHERE code = $1", flow), key)
    if not facts:
        raise ana.Error("NOT_FOUND", f"{d['document']} {key} não encontrado")
    facts = {**facts, "key": key}
    steps = ana.sql("SELECT seq, code, name, program, params, mode, done_sql FROM flow.step WHERE flow_code = $1 ORDER BY seq", flow)
    done = [bool(ana.sql_value(s["done_sql"], key)) for s in steps]
    # Current: the first stage not done (a later stage done by hand does not hide an earlier one left behind).
    current = next((i for i, x in enumerate(done) if not x), None)
    items = []
    for i, s in enumerate(steps):
        status = "done" if done[i] else ("current" if i == current else "todo")
        hint = {"done": "concluída", "current": "é aqui", "todo": "depois"}[status]
        if status == "current" and s["mode"] == "wait":
            hint = "aguardando (acontece fora daqui: pagamento, execução…)"
        items.append({"label": s["name"], "status": status, "hint": hint})
    who = facts.get("customer") or facts.get("requester") or facts.get("product") or ""
    ana.steps(items, title=f"{d['name']}: {d['document']} {key}" + (f" — {who}" if who else ""))
    actions = []
    if current is not None:
        s = steps[current]
        if s["program"]:
            params = {k: v for k, v in common.render(s["params"], facts).items() if v is not None}
            actions.append({"label": f"Fazer agora: {s['name']}", "program": s["program"], "open": True, "style": "primary",
                            "params": {**params, "_form": "1"}})
    if flow in DOC_KIND:
        actions.append({"label": "Abrir documento", **doc_link(DOC_KIND[flow], key), "open": True})
    if d["active"]:
        actions.append({"label": "Ver na esteira", "program": "flows.board", "params": {"flow": flow, "document": key}, "open": True})
    ana.actions(actions, title="Concluído: nada a fazer" if current is None else "Próximo passo")
    return {"flow": flow, "document": key, "current": steps[current]["code"] if current is not None else None,
            "done": [s["code"] for s, x in zip(steps, done) if x]}
