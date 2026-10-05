# ana:description Emite cobrança (PIX, boleto ou link de cartão) de um título a receber por um gateway
# ana:exposed yes
"""RF-017-08. The request goes to the connector's outbox in this same transaction; the
connector's delivery program talks to the gateway and fills the charge (id, QR code, line).
One open charge per bill."""

PARAMS = {
    "bill": {"type": "int", "required": True, "label": "título a receber"},
    "method": {"type": "str", "default": "pix", "label": "forma",
               "choices": [["pix", "PIX"], ["boleto", "Boleto"], ["card_link", "Link de cartão"]]},
    "connector": {"type": "str", "required": True, "label": "conector do gateway"},
}


def main(bill, connector, method="pix"):
    b = ana.sql_one("SELECT b.id, b.kind, b.status, b.amount, b.due_date, b.document, p.name, p.tax_id, p.email "
                    "FROM finance.bill b JOIN base.party p ON p.id = b.party_id WHERE b.id = $1 FOR UPDATE OF b", bill)
    if not b:
        raise ana.Error("BILL_NOT_FOUND", f"título {bill} não encontrado")
    if b["kind"] != "receivable" or b["status"] != "open":
        raise ana.Error("BILL_NOT_OPEN", "só títulos a receber em aberto podem ser cobrados")
    if ana.sql_value("SELECT count(*) FROM finance.charge WHERE bill_id = $1 AND status IN ('requested', 'issued')", bill):
        raise ana.Error("CHARGE_EXISTS", "o título já tem cobrança em aberto")
    charge = ana.sql_value("INSERT INTO finance.charge (bill_id, connector, method, amount, created_by) "
                           "VALUES ($1, $2, $3, $4, $5) RETURNING id", bill, connector, method, b["amount"], ana.context.user)
    message = ana.send(connector, "charge.create", {
        "charge": charge, "bill": bill, "document": b["document"], "method": method, "amount": b["amount"],
        "due_date": b["due_date"], "payer": {"name": b["name"], "tax_id": b["tax_id"], "email": b["email"]}},
        key=f"bill-{bill}")
    ana.log(f"cobrança {charge} pedida ao conector {connector} (mensagem {message})")
    return {"charge": charge, "message": message, "status": "requested"}
