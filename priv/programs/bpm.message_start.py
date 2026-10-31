# ana:description Processos: inicia casos a partir de mensagens que chegam por um conector de integração
# ana:category Processos/Modelagem
# ana:menu no
"""Spec 039 (T-039-17b) with spec 017. Set as a connector's inbound program (Administração → Integrações) — or called
by the connector's own inbound program — every message received starts a case of each published process whose
start is "por mensagem" from that connector (and of that event type, when the process names one). The message
becomes the case's data; the field the process names gives the document key the case follows. A message that no
process takes is not an error (it is recorded as delivered, with nothing started)."""

from ana_lib.bpm import common

PARAMS = {"event": {"type": "dict", "required": True, "label": "mensagem recebida"},
          "connector": {"type": "dict", "label": "conector"},
          "attempt": {"type": "int", "label": "tentativa"}}
DATA_MAX = 64 * 1024


def main(event, connector=None, attempt=None):
    name = (connector or {}).get("name") or event.get("connector")
    payload = event.get("payload") if isinstance(event.get("payload"), dict) else {"value": event.get("payload")}
    kind = str(payload.get("type") or payload.get("event") or "")
    procs = ana.sql("SELECT v.process_code, v.compiled -> 'message' AS m FROM bpm.version v JOIN bpm.process p ON p.code = v.process_code "
                    "WHERE v.status = 'published' AND p.active AND p.flow_code IS NULL AND v.compiled -> 'message' ->> 'connector' = $1 "
                    "ORDER BY v.process_code", name)
    started, skipped = [], []
    data = payload if len(str(payload)) <= DATA_MAX else {"truncated": True}
    for p in procs:
        m = p["m"] or {}
        if m.get("event_type") and m["event_type"] != kind:
            continue
        doc = payload.get(m["document_field"]) if m.get("document_field") else None
        if m.get("document_field") and doc in (None, ""):
            skipped.append({"process": p["process_code"], "reason": f"mensagem sem o campo {m['document_field']}"})
            continue
        # ana:lint-ok sql_in_loop — one case per process that takes this message (a handful)
        r = ana.call("bpm.start", process=p["process_code"], document=str(doc) if doc is not None else None,
                     title=f"{common.process(p['process_code'])['name']} — mensagem {event.get('event_id') or ''}".strip(" —"),
                     data={"message": data, "event_id": event.get("event_id"), "connector": name})
        started.append({"process": p["process_code"], "case": r["case"]})
    for s in skipped:
        ana.log(f"{s['process']}: {s['reason']}", "warning")
    return {"started": started, "skipped": skipped}
