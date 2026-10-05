# ana:description Modelo de conector: entrega pedidos de cobrança a um gateway HTTP/JSON genérico
# ana:menu no
"""Template for gateway connectors (spec 017, RF-017-10): copy it and adapt the mapping.

Contract: POST <charges_path> with the charge as JSON; the answer has id and, as the method
asks, qr_code, digitable_line or url. Connector options: charges_path (default /charges),
response_field (unwraps the answer, e.g. "result"). 5xx/network → retried; 4xx → charge failed."""

PARAMS = {"message": {"type": "dict", "required": True}, "connector": {"type": "dict", "required": True},
          "attempt": {"type": "int"}}


def main(message, connector, attempt=1):
    if message["kind"] != "charge.create":
        return {"ignored": message["kind"]}
    p = message["payload"]
    opts = connector.get("options") or {}
    r = ana.http(connector["name"], "POST", opts.get("charges_path", "/charges"), json=p,
                 headers={"Idempotency-Key": f"charge-{p['charge']}"})
    if r["status"] >= 500:
        raise ana.Error("GATEWAY_UNAVAILABLE", f"gateway respondeu HTTP {r['status']}")
    if not r.ok:
        ana.sql_exec("UPDATE finance.charge SET status = 'failed' WHERE id = $1 AND status = 'requested'", p["charge"])
        return {"failed": r["status"]}
    data = r.get("json") or {}
    if opts.get("response_field"):
        data = data.get(opts["response_field"]) or {}
    if not data.get("id"):
        raise ana.Error("GATEWAY_INVALID", "resposta do gateway sem id da cobrança")
    ana.sql_exec("UPDATE finance.charge SET status = 'issued', external_id = $2, qr_code = $3, digitable_line = $4, url = $5 "
                 "WHERE id = $1 AND status = 'requested'", p["charge"], str(data["id"]), data.get("qr_code"),
                 data.get("digitable_line"), data.get("url"))
    return {"charge": p["charge"], "external_id": str(data["id"])}
