# ana:description Liquida o título de uma cobrança paga no gateway (idempotente)
# ana:exposed yes
"""RF-017-08, RNF-017-02: the same payment event applied twice settles once. Spec 038 (RF-038-07): the money
is not in the bank yet — it is with the gateway until the payout: D gateway receivable (net) + D bank fees
(the gateway's fee) / C the bill's control account. The payout in the statement later clears the gateway
receivable (finance.reconcile). Paying less leaves a residual bill; more becomes a customer credit. A bill
already settled by another path (e.g. the bank statement) only marks the charge as paid."""

import datetime
from decimal import Decimal

from ana_lib.finance import banking
from ana_lib.docs import pdfs

PARAMS = {
    "external_id": {"type": "str", "required": True, "label": "identificador no gateway"},
    "amount": {"type": "decimal", "label": "valor pago"},
    "fee": {"type": "decimal", "default": 0, "label": "tarifa do gateway"},
    "bank_account": {"type": "str", "default": "CAIXA", "label": "conta que recebe o repasse (informativo)", "lookup": {"program": "finance.lookup", "params": {"kind": "bank_accounts"}}},
    "event_id": {"type": "str", "label": "evento"},
    "paid_on": {"type": "date", "label": "data do pagamento"},
}


def main(external_id, amount=None, fee=0, bank_account="CAIXA", event_id=None, paid_on=None):
    rows = ana.sql("SELECT c.id, c.status, c.amount, c.bill_id, b.status AS bill_status, b.party_id "
                   "FROM finance.charge c JOIN finance.bill b ON b.id = c.bill_id WHERE c.external_id = $1 "
                   "FOR UPDATE OF c, b", external_id)
    if not rows:
        raise ana.Error("CHARGE_NOT_FOUND", f"cobrança {external_id} não encontrada")
    if len(rows) > 1:
        raise ana.Error("CHARGE_AMBIGUOUS", f"mais de um gateway com a cobrança {external_id}")
    c = rows[0]
    if c["status"] == "paid":
        return {"charge": c["id"], "already_paid": True}
    if c["status"] in ("cancelled", "failed"):
        raise ana.Error("CHARGE_NOT_PAYABLE", f"cobrança {external_id} está {c['status']}")
    paid = Decimal(str(amount)) if amount is not None else c["amount"]
    fee = Decimal(str(fee or 0))
    entry = None
    net = paid - fee
    if c["bill_status"] == "open":
        tol = Decimal(banking.policy()["tolerance"])
        bill = banking.bills_by_id([c["bill_id"]])[c["bill_id"]]
        applied, residuals, _, adjustment, excess = banking.allocate([bill], paid, tol)
        entry = ana.sql_value("INSERT INTO finance.journal_entry (entry_date, memo, document, created_by) "
                              "VALUES ($1, $2, $3, $4) RETURNING id", paid_on or datetime.date.today(),
                              f"Pagamento da cobrança {external_id}", f"CHG-{c['id']}", ana.context.user)
        jl = [[entry, "@gateway_receivable", net, 0]] + ([[entry, "@bank_fees", fee, 0]] if fee else [])
        jl += [[entry, b["account"], 0, v] for b, v in applied]
        if adjustment > 0:
            jl.append([entry, "@interest_received", 0, adjustment])
        elif adjustment < 0:
            jl.append([entry, "@bank_fees", -adjustment, 0])
        if excess > 0:
            jl.append([entry, "@customer_credits", 0, excess])
        ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit) VALUES ($1, "
                      "CASE WHEN left($2, 1) = '@' THEN finance.account_for(substr($2, 2)) ELSE $2 END, $3, $4)", jl)
        ana.sql_exec("UPDATE finance.bill SET status = 'settled' WHERE id = $1", c["bill_id"])
        for b, rest in residuals:
            banking.residual(b["id"], rest)
        if excess > 0:
            banking.credit_bill("receivable", c["party_id"], f"CRED-CHG-{c['id']}", excess, entry)
        if banking.policy()["auto_offset"]:
            banking.offset(c["party_id"], ana.context.user)
    ana.sql_exec("UPDATE finance.charge SET status = 'paid', paid_amount = $2, fee = $3, paid_at = now(), event_id = $4, "
                 "entry_id = $5, net = CASE WHEN $5::bigint IS NOT NULL THEN $6::numeric END WHERE id = $1",
                 c["id"], paid, fee, event_id, entry, net)
    if entry is not None:
        pdfs.publish_quietly("receipt", c["bill_id"])   # spec 037: payment receipt
    return {"charge": c["id"], "settled": entry is not None, "entry": entry}
