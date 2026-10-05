# ana:description Condições de pagamento e crédito: parcelas, escolha da condição e checagem de bloqueio
# ana:kind library
"""Spec 031. schedule() splits an amount into installments (cents in the last one); term_for()
picks the order's term, else the customer's default, else the policy's; check_credit() refuses a
blocked customer unless a one-time release exists for that order (it is consumed)."""

import datetime
from decimal import Decimal, ROUND_HALF_UP

import ana

CENT = Decimal("0.01")


def get_term(code):
    t = ana.sql_one("SELECT code, name, method, installments, down_payment_pct, adjust_pct, fee_pct, min_amount, connector, active "
                    "FROM finance.payment_term WHERE code = $1", str(code).strip().upper())
    if not t or not t["active"]:
        raise ana.Error("PAYMENT_TERM_NOT_FOUND", f"condição de pagamento {code} inexistente ou inativa")
    return t


def adjusted(amount, term):
    return (Decimal(amount) * (1 + Decimal(term["adjust_pct"]) / 100)).quantize(CENT, ROUND_HALF_UP)


def schedule(amount, term, issue=None):
    """[(n, due_date, amount)] for `amount` (already adjusted); the last installment takes the cents."""
    issue = issue or datetime.date.today()
    parts = []
    if term["down_payment_pct"] and Decimal(term["down_payment_pct"]) > 0:
        parts.append((0, Decimal(term["down_payment_pct"])))
    parts += [(int(i["days"]), Decimal(str(i["pct"]))) for i in term["installments"]]
    out, used = [], Decimal(0)
    for k, (days, pct) in enumerate(parts, start=1):
        value = (Decimal(amount) - used) if k == len(parts) else (Decimal(amount) * pct / 100).quantize(CENT, ROUND_HALF_UP)
        used += value
        out.append((k, issue + datetime.timedelta(days=days), value))
    return out


def term_for(customer, given=None):
    code = given or ana.sql_value("SELECT COALESCE((SELECT default_term FROM finance.credit_profile WHERE party_id = $1), "
                                  "(SELECT default_term FROM finance.credit_policy WHERE id = 1))", customer)
    return get_term(code) if code else None


def require_allowed(customer, term, amount):
    allowed = [r["term"] for r in ana.sql("SELECT term FROM finance.party_payment_term WHERE party_id = $1", customer)]
    if allowed and term["code"] not in allowed:
        raise ana.Error("PAYMENT_TERM_NOT_ALLOWED", f"condição {term['code']} não liberada para este cliente: {', '.join(sorted(allowed))}")
    if Decimal(amount) < Decimal(term["min_amount"]):
        raise ana.Error("BELOW_MINIMUM", f"valor abaixo do mínimo de R$ {term['min_amount']} da condição {term['code']}")


def check_credit(customer, extra, scope, order_id=None):
    """Raises CUSTOMER_BLOCKED (with the reason) unless the customer may buy/be invoiced now."""
    st = ana.sql_one("SELECT blocked, reason, open_amount, overdue_amount, credit_limit, available "
                     "FROM finance.credit_status($1, $2)", customer, extra)
    if not st["blocked"]:
        return st
    release = ana.sql_value("SELECT id FROM finance.credit_release WHERE party_id = $1 AND scope = $2 AND used_at IS NULL "
                            "AND (sales_order_id IS NULL OR sales_order_id = $3) ORDER BY sales_order_id NULLS LAST, id LIMIT 1 "
                            "FOR UPDATE", customer, scope, order_id)
    if release:
        ana.sql_exec("UPDATE finance.credit_release SET used_at = now(), sales_order_id = COALESCE(sales_order_id, $2) WHERE id = $1",
                     release, order_id)
        ana.log(f"cliente bloqueado ({st['reason']}), liberado por exceção registrada", "warning")
        return st
    raise ana.Error("CUSTOMER_BLOCKED", f"cliente bloqueado — {st['reason']}",
                    {"reason": st["reason"], "overdue": st["overdue_amount"], "available": st["available"]})
