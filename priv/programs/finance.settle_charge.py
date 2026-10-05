# ana:description Liquida o título de uma cobrança paga no gateway (idempotente)
# ana:exposed yes
"""RF-017-08, RNF-017-02: the same payment event applied twice settles once. Posts
D bank / C customers and the gateway fee (D bank_fees / C bank). A bill already settled by
another path (e.g. the bank statement) only marks the charge as paid."""

import datetime
from decimal import Decimal

from ana_lib.finance import banking

PARAMS = {
    "external_id": {"type": "str", "required": True, "label": "identificador no gateway"},
    "amount": {"type": "decimal", "label": "valor pago"},
    "fee": {"type": "decimal", "default": 0, "label": "tarifa do gateway"},
    "bank_account": {"type": "str", "default": "CAIXA", "label": "conta que recebe", "lookup": {"program": "finance.lookup", "params": {"kind": "bank_accounts"}}},
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
    if c["bill_status"] == "open":
        ledger = banking.bank_ledger(bank_account.strip().upper())
        entry = ana.sql_value("INSERT INTO finance.journal_entry (entry_date, memo, document, created_by) "
                              "VALUES ($1, $2, $3, $4) RETURNING id", paid_on or datetime.date.today(),
                              f"Pagamento da cobrança {external_id}", f"CHG-{c['id']}", ana.context.user)
        jl = [[entry, ledger, paid, 0], [entry, "@customers", 0, c["amount"]]]
        if paid != c["amount"]:
            diff = paid - c["amount"]
            jl.append([entry, "@interest_received", 0, diff] if diff > 0 else [entry, "@bank_fees", -diff, 0])
        if fee:
            jl += [[entry, "@bank_fees", fee, 0], [entry, ledger, 0, fee]]
        ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit) VALUES ($1, "
                      "CASE WHEN left($2, 1) = '@' THEN finance.account_for(substr($2, 2)) ELSE $2 END, $3, $4)", jl)
        ana.sql_exec("UPDATE finance.bill SET status = 'settled' WHERE id = $1", c["bill_id"])
    ana.sql_exec("UPDATE finance.charge SET status = 'paid', paid_amount = $2, fee = $3, paid_at = now(), event_id = $4, "
                 "entry_id = $5 WHERE id = $1", c["id"], paid, fee, event_id, entry)
    return {"charge": c["id"], "settled": entry is not None, "entry": entry}
