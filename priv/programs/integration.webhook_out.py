# ana:description Entrega genérica de eventos a um sistema externo por webhook: JSON assinado, uma vez e em ordem
# ana:menu no
"""Spec 068 (D11) and spec 017. The outbound program of a connector that only needs the event delivered: POST <path>
with the message as JSON. The core signs "<timestamp>.<body>" with the connector's hmac_key (HMAC-SHA256, the same
scheme the ANA checks on its own inbound webhooks) and sends the event id, so the destination drops a repeat.
Connector options: path (default /events). 5xx or network → retried later; 4xx → the destination refused it: the
message is marked dead for an administrator to look at (spec 017)."""

PARAMS = {
    "message": {"type": "dict", "required": True, "label": "mensagem"},
    "connector": {"type": "dict", "required": True, "label": "conector"},
    "attempt": {"type": "int", "label": "tentativa"},
}


def main(message, connector, attempt=1):
    opts = connector.get("options") or {}
    body = {"id": message.get("event_id") or f"outbox-{message['id']}", "kind": message["kind"],
            "data": message["payload"]}
    r = ana.http(connector["name"], "POST", opts.get("path", "/events"), json=body, sign=True,
                 event_id=body["id"])
    if r["status"] >= 500:
        raise ana.Error("DESTINATION_UNAVAILABLE", f"destino respondeu HTTP {r['status']}: nova tentativa mais tarde")
    if not r.ok:
        raise ana.Error("DESTINATION_REFUSED", f"destino recusou a mensagem (HTTP {r['status']})",
                        {"permanent": True, "status": r["status"]})
    return {"delivered": body["id"], "status": r["status"]}
