# ana:description Esteira: onde está cada documento, o que espera uma pessoa e o que falhou
# ana:command esteiras
# ana:category Processos/Esteiras
"""RF-030-04, RF-030-05, H6. One column per step with the open documents; each card says why
it is waiting (manual step, condition not met, outside event) or the failure, with the next
action: do it now (opens the step's routine with the document filled in), run automatically
now, reprocess, or skip with a reason."""

from ana_lib.docs.common import link as doc_link
from ana_lib.flows import common

DOC_KIND = {"sales": "order", "purchase": "purchase_request", "field": "service_order", "production": "work_order"}

PARAMS = {
    "flow": {"type": "str", "required": True, "default": "sales", "label": "esteira", "order": 1,
             "lookup": {"program": "flows.lookup", "params": {"kind": "flows"}}},
    "document": {"type": "str", "label": "documento (nº)", "order": 2},
}


def main(flow="sales", document=None):
    d = common.definition(flow)
    steps = ana.sql("SELECT seq, code, name, program, params, mode, condition FROM flow.step WHERE flow_code = $1 ORDER BY seq", flow)
    by_seq = {s["seq"]: s for s in steps}
    counts = ana.sql_one(
        "SELECT count(*) FILTER (WHERE status = 'running') AS running, count(*) FILTER (WHERE status = 'waiting') AS waiting, "
        "  count(*) FILTER (WHERE status = 'failed') AS failed, "
        "  count(*) FILTER (WHERE status = 'done' AND finished_at > now() - interval '7 days') AS done7 "
        "FROM flow.instance WHERE flow_code = $1", flow)
    ana.metrics([{"label": "Em andamento", "value": counts["running"]},
                 {"label": "Aguardando uma pessoa", "value": counts["waiting"], "status": "warn" if counts["waiting"] else "ok"},
                 {"label": "Com falha", "value": counts["failed"], "status": "bad" if counts["failed"] else "ok"},
                 {"label": "Concluídas em 7 dias", "value": counts["done7"]}],
                title=f"{d['name']} — {d['description']}")
    if not d["active"]:
        ana.actions([{"label": "Configurar e ligar a esteira", "program": "flows.configure", "params": {"flow": flow}, "open": True,
                      "style": "primary"}], title="Esteira desligada: nenhum documento novo entra nela")
    rows = ana.sql(
        "SELECT i.id, i.doc_key, i.status, i.current_seq, i.facts, x.status AS step_status, x.reason, x.error, x.attempts, "
        "  x.next_at, i.updated_at "
        "FROM flow.instance i JOIN flow.instance_step x ON x.instance_id = i.id AND x.seq = i.current_seq "
        "WHERE i.flow_code = $1 AND i.status IN ('running', 'waiting', 'failed') AND ($2::text IS NULL OR i.doc_key = $2) "
        "ORDER BY i.status = 'failed' DESC, i.updated_at LIMIT 500", flow, document)
    cards = []
    for r in rows:
        s = by_seq.get(r["current_seq"])
        if not s:
            continue
        facts = r["facts"] or {"key": r["doc_key"]}
        who = facts.get("customer") or facts.get("product") or facts.get("requester") or ""
        actions = [{"label": "Abrir documento", **doc_link(DOC_KIND[flow], r["doc_key"]), "open": True}] if flow in DOC_KIND else []
        if r["step_status"] in ("waiting", "failed") and s["program"]:
            actions.append({"label": "Fazer agora", "program": s["program"], "open": True, "style": "primary",
                            "params": {**{k: v for k, v in common.render(s["params"], facts).items() if v is not None}, "_form": "1"}})
            actions.append({"label": "Reprocessar" if r["step_status"] == "failed" else "Executar automaticamente",
                            "program": "flows.act", "params": {"instance": r["id"], "seq": s["seq"],
                                                               "action": "retry" if r["step_status"] == "failed" else "run"},
                            "confirm": f"Rodar a etapa {s['name']} de {d['document']} {r['doc_key']} agora?"})
        if r["step_status"] in ("waiting", "failed", "ready"):
            actions.append({"label": "Pular", "program": "flows.act", "params": {"instance": r["id"], "seq": s["seq"], "action": "skip"},
                            "ask": {"reason": {"type": "str", "required": True, "label": "motivo"}}})
        if r["step_status"] == "failed":
            e = r["error"] or {}
            subtitle = f"falhou: {e.get('message') or e.get('code') or 'erro'}"
        elif r["step_status"] == "waiting":
            subtitle = r["reason"] or "aguardando"
        elif r["step_status"] == "ready" and r["attempts"]:
            subtitle = f"nova tentativa às {str(r['next_at'])[11:16]}" if r["next_at"] else "na fila"
        else:
            subtitle = common.STEP_STATUS.get(r["step_status"], r["step_status"])
        cards.append({"column": s["code"], "title": f"{d['document'].capitalize()} {r['doc_key']}" + (f" — {who}" if who else ""),
                      "subtitle": subtitle,
                      "badges": [common.STEP_STATUS.get(r["step_status"], r["step_status"])]
                                + ([common.MODE[s["mode"]]] if s["mode"] != "manual" else []),
                      "actions": actions})
    ana.board([{"key": s["code"], "label": f"{s['seq']}. {s['name']} ({common.MODE[s['mode']]})"} for s in steps], cards,
              title=f"Documentos em aberto ({len(cards)})")

    failed = [r for r in rows if r["step_status"] == "failed"]
    if failed:
        ana.table([{"documento": r["doc_key"], "etapa": by_seq[r["current_seq"]]["name"],
                    "erro": (r["error"] or {}).get("code"), "mensagem": (r["error"] or {}).get("message"),
                    "tentativas": r["attempts"]} for r in failed if r["current_seq"] in by_seq], title="Falhas")
    if document:
        history = ana.sql(
            "SELECT s.seq, s.name, x.status, x.how, x.done_by, x.reason, x.started_at, x.finished_at, x.execution_id "
            "FROM flow.instance i JOIN flow.instance_step x ON x.instance_id = i.id "
            "JOIN flow.step s ON s.flow_code = i.flow_code AND s.seq = x.seq "
            "WHERE i.flow_code = $1 AND i.doc_key = $2 ORDER BY s.seq", flow, document)
        ana.table([{"etapa": f"{h['seq']}. {h['name']}", "situação": common.STEP_STATUS.get(h["status"], h["status"]),
                    "como": common.HOW.get(h["how"], ""), "por": h["done_by"] or "", "motivo": h["reason"] or "",
                    "fim": h["finished_at"]} for h in history], title=f"Histórico de {d['document']} {document}")
    return {"flow": flow, "active": d["active"], "open": len(cards), "failed": len(failed)}
