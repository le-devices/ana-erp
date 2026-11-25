# ana:description Condição de uma etapa da esteira: construtor de condições e simulação dos documentos que ela pega
# ana:role admin
# ana:category Processos/Esteiras
"""Spec 030 (RF-030-02) with the patterns of spec 020: the condition is built with criteria (E inside, OU
between them) and exceptions (RF-020-14) and, before saving, "Simular" shows which documents of the flow
would make the step automatic (RF-020-13). The rule is the restricted one the engine evaluates
(ana_flows:condition/2) — never code."""

import json

from ana_lib.flows import common
from ana_lib.util import conditions

PARAMS = {
    "flow": {"type": "str", "required": True, "default": "sales", "label": "esteira", "order": 1,
             "lookup": {"program": "flows.lookup", "params": {"kind": "flows"}}},
    "step": {"type": "int", "required": True, "label": "etapa", "order": 2,
             "lookup": {"program": "flows.lookup", "params": {"kind": "steps"}, "depends": ["flow"]}},
    "condition": {"type": "condition", "label": "condição para a etapa ser automática", "order": 3,
                  "fields": {"program": "flows.lookup", "params": {"kind": "facts"}, "depends": ["flow"]}},
    "simulate": {"type": "bool", "simulate": True, "label": "simular (não grava)", "order": 4},
}
SAMPLE = 500


def main(flow="sales", step=None, condition=None, simulate=False):
    common.definition(flow)
    s = ana.sql_one("SELECT seq, name, mode, condition FROM flow.step WHERE flow_code = $1 AND seq = $2", flow, step)
    if not s:
        raise ana.Error("STEP_NOT_FOUND", f"etapa {step} não existe nesta esteira")
    if s["mode"] == "wait":
        raise ana.Error("INVALID_OPERATION", "esta etapa aguarda um evento externo: não tem condição")
    labels = common.fact_labels(flow)
    rule = conditions.validate(condition if condition is not None else s["condition"])
    stored = conditions.compact(rule)
    text = conditions.text(stored, labels)
    if simulate:
        docs = ana.sql("SELECT doc_key, status, current_seq, facts FROM flow.instance WHERE flow_code = $1 AND facts IS NOT NULL "
                       "ORDER BY (status IN ('running', 'waiting', 'failed')) DESC, id DESC LIMIT $2", flow, SAMPLE)
        hits = [d for d in docs if conditions.holds(stored, d["facts"])]
        ana.metrics([{"label": "Documentos que a condição pega", "value": f"{len(hits)} de {len(docs)}",
                      "hint": "os mais recentes da esteira, em aberto primeiro"},
                     {"label": "Regra", "value": text}], title=f"Simulação: etapa {s['seq']}. {s['name']}")
        keys = sorted({k for d in hits for k in (d["facts"] or {}) if k != "key"})[:8]
        ana.table([{"documento": d["doc_key"], "situação": common.INSTANCE_STATUS.get(d["status"], d["status"]),
                    **{labels.get(k, k): d["facts"].get(k) for k in keys},
                    "_open": {"program": "flows.board", "params": {"flow": flow, "document": d["doc_key"]}}} for d in hits],
                  title="Documentos que tornariam a etapa automática",
                  empty="Nenhum documento recente da esteira atende esta condição.",
                  empty_action={"label": "Ver a esteira", "program": "flows.board", "params": {"flow": flow}})
        return {"simulated": True, "matches": len(hits), "sample": len(docs), "text": text}
    ana.sql_exec("UPDATE flow.step SET condition = $3::text::jsonb WHERE flow_code = $1 AND seq = $2", flow, step, json.dumps(stored))
    ana.sql_exec("UPDATE flow.definition SET updated_by = $2, updated_at = now() WHERE code = $1", flow, ana.context.user)
    ana.log(f"etapa {s['seq']}. {s['name']}: automática quando {text}")
    return {"flow": flow, "step": step, "condition": stored, "text": text}
