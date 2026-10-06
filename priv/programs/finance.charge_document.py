# ana:description Emite as cobranças (PIX, boleto ou cartão) dos títulos em aberto de um documento
# ana:command cobrar
"""RF-030 (Venda e Campo: etapa Cobrança). For every open receivable bill of the document
("ORD-12" or its installments "ORD-12/1"…) whose payment term has a gateway connector and
no charge yet, asks finance.create_charge. Bills without a connector are left as they are
(boleto printed by the bank, cash, transfer): nothing to charge through a gateway."""

PARAMS = {
    "document": {"type": "str", "required": True, "label": "documento (ex.: ORD-12, OS-5)"},
}
METHOD = {"pix": "pix", "boleto": "boleto", "credit_card": "card_link"}


def main(document):
    document = document.strip().upper()
    bills = ana.sql(
        "SELECT b.id, b.document, b.amount, t.connector, t.method FROM finance.bill b "
        "LEFT JOIN finance.payment_term t ON t.code = b.payment_term "
        "WHERE b.kind = 'receivable' AND b.status = 'open' AND (b.document = $1 OR b.document LIKE $1 || '/%') "
        "AND NOT EXISTS (SELECT 1 FROM finance.charge c WHERE c.bill_id = b.id AND c.status NOT IN ('cancelled', 'failed')) "
        "ORDER BY b.id", document)
    charged, without = [], []
    for b in bills:
        if b["connector"] and b["method"] in METHOD:
            # ana:lint-ok sql_in_loop — one charge per installment (each is a message in the outbox)
            r = ana.call("finance.create_charge", bill=b["id"], connector=b["connector"], method=METHOD[b["method"]])
            charged.append({"bill": b["id"], "document": b["document"], "charge": r["charge"]})
        else:
            without.append(b["document"])
    if without:
        ana.log(f"sem cobrança por gateway (condição sem conector): {', '.join(without)}")
    return {"document": document, "charged": charged, "without_gateway": without}
