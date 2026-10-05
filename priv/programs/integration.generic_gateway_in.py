# ana:description Modelo de conector: processa avisos de pagamento de um gateway genérico (webhook)
# ana:menu no
"""Template for gateway webhooks (spec 017, RF-017-10): copy it and adapt the mapping.

Expected event: {"id", "type": "charge.paid", "charge_id", "amount", "fee"?, "paid_at"?}.
Other types are acknowledged and ignored. Settling is idempotent (finance.settle_charge)."""

PARAMS = {
    "event": {"type": "dict", "required": True, "label": "evento"},
    "connector": {"type": "dict", "required": True, "label": "conector"},
    "attempt": {"type": "int", "label": "tentativa"},
}


def main(event, connector, attempt=1):
    e = event["payload"]
    if e.get("type") != "charge.paid":
        return {"ignored": e.get("type")}
    opts = connector.get("options") or {}
    return ana.call("finance.settle_charge", external_id=str(e["charge_id"]), amount=e.get("amount"),
                    fee=e.get("fee") or 0, event_id=event["event_id"], bank_account=opts.get("bank_account", "CAIXA"))
