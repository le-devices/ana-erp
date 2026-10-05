# ana:description Regras de conciliação bancária (candidatos por conjunto)
# ana:kind library
"""Candidates for every open statement line of an account (spec 017, RF-017-07)."""

from decimal import Decimal

import ana


def candidates(account, tolerance_days):
    # ana:lint-ok leading_wildcard — open lines × issued/paid charges and open bills, bounded by the open set
    rows = ana.sql(
        "WITH l AS (SELECT id, posted_on, amount, lower(description || ' ' || COALESCE(document, '')) AS txt "
        "           FROM finance.bank_statement_line WHERE bank_account = $1 AND status = 'open'), "
        "c1 AS (SELECT l.id AS line_id, ch.bill_id, 'charge' AS rule, 1.0 AS confidence, ch.id AS charge_id, "
        "              ch.status AS charge_status, ch.entry_id AS charge_entry "
        "       FROM l JOIN finance.charge ch ON length(ch.external_id) >= 6 "
        "         AND l.txt LIKE '%' || lower(ch.external_id) || '%' AND ch.status IN ('issued', 'paid')), "
        "c2 AS (SELECT l.id, b.id, 'document', 0.95, NULL::bigint, NULL::text, NULL::bigint "
        "       FROM l JOIN finance.bill b ON b.status = 'open' AND b.amount = abs(l.amount) "
        "         AND b.kind = CASE WHEN l.amount > 0 THEN 'receivable' ELSE 'payable' END "
        "         AND length(b.document) >= 4 AND l.txt LIKE '%' || lower(b.document) || '%'), "
        "c3 AS (SELECT l.id, b.id, 'amount_date', 0.8, NULL::bigint, NULL::text, NULL::bigint "
        "       FROM l JOIN finance.bill b ON b.status = 'open' AND b.amount = abs(l.amount) "
        "         AND b.kind = CASE WHEN l.amount > 0 THEN 'receivable' ELSE 'payable' END "
        "         AND b.due_date BETWEEN l.posted_on - $2::int AND l.posted_on + $2::int) "
        "SELECT * FROM c1 UNION ALL SELECT * FROM c2 UNION ALL SELECT * FROM c3", account, tolerance_days)
    by_line = {}
    for r in rows:
        by_line.setdefault(r["line_id"], []).append(r)
    best = {}
    for line_id, cands in by_line.items():
        for rule in ("charge", "document", "amount_date"):
            found = [c for c in cands if c["rule"] == rule]
            if found:
                if rule == "amount_date" and len(found) > 1:
                    found = [{**c, "confidence": Decimal("0.5")} for c in found]
                best[line_id] = found
                break
    return best
