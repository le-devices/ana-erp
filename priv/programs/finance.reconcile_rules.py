# ana:description Regras de conciliação bancária (candidatos por conjunto)
# ana:kind library
"""Candidates for every open statement line of an account (spec 017, RF-017-07)."""

from decimal import Decimal

import ana


def candidates(account, tolerance_days, only=None, bills=None):
    """only: ids of the lines to look at (an import reconciles what it brought, not the whole backlog);
    bills: only these bills as candidates (to find who else wants them)."""
    # ana:lint-ok leading_wildcard — open lines × issued/paid charges and open bills, bounded by the open set
    rows = ana.sql(
        "WITH l AS (SELECT id, posted_on, amount, lower(description || ' ' || COALESCE(document, '')) AS txt "
        "           FROM finance.bank_statement_line WHERE bank_account = $1 AND status = 'open' AND ($3::bigint[] IS NULL OR id IN (SELECT unnest($3::bigint[])))), "
        "c1 AS (SELECT x.id AS line_id, ch.bill_id, 'charge' AS rule, 1.0 AS confidence, ch.id AS charge_id, "
        "              ch.status AS charge_status, ch.entry_id AS charge_entry "
        # One trigram-index lookup per charge that can still meet a line (issued, or paid and not yet paid out).
        "       FROM finance.charge ch JOIN finance.bank_statement_line x "
        "         ON lower(x.description || ' ' || COALESCE(x.document, '')) LIKE '%' || lower(ch.external_id) || '%' "
        "       WHERE length(ch.external_id) >= 6 AND (ch.status = 'issued' OR (ch.status = 'paid' AND ch.payout_line_id IS NULL)) "
        "         AND x.bank_account = $1 AND x.status = 'open' AND ($3::bigint[] IS NULL OR x.id IN (SELECT unnest($3::bigint[]))) "
        "         AND ($4::bigint[] IS NULL OR ch.bill_id = ANY($4))), "
        "c2 AS (SELECT l.id AS line_id, b.id AS bill_id, 'document' AS rule, 0.95 AS confidence, NULL::bigint AS charge_id, "
        "              NULL::text AS charge_status, NULL::bigint AS charge_entry "
        "       FROM l JOIN finance.bill b ON b.status = 'open' AND b.amount = abs(l.amount) AND ($4::bigint[] IS NULL OR b.id = ANY($4)) "
        "         AND b.kind = CASE WHEN l.amount > 0 THEN 'receivable' ELSE 'payable' END "
        "         AND length(b.document) >= 4 AND l.txt LIKE '%' || lower(b.document) || '%'), "
        "c3 AS (SELECT l.id AS line_id, b.id AS bill_id, 'amount_date' AS rule, 0.8 AS confidence, NULL::bigint AS charge_id, "
        "              NULL::text AS charge_status, NULL::bigint AS charge_entry "
        "       FROM l JOIN finance.bill b ON b.status = 'open' AND b.amount = abs(l.amount) AND ($4::bigint[] IS NULL OR b.id = ANY($4)) "
        "         AND b.kind = CASE WHEN l.amount > 0 THEN 'receivable' ELSE 'payable' END "
        "         AND b.due_date BETWEEN l.posted_on - $2::int AND l.posted_on + $2::int) "
        "SELECT line_id, bill_id, rule, confidence, charge_id, charge_status, charge_entry FROM c1 "
        "UNION ALL SELECT line_id, bill_id, rule, confidence, charge_id, charge_status, charge_entry FROM c2 "
        "UNION ALL SELECT line_id, bill_id, rule, confidence, charge_id, charge_status, charge_entry FROM c3", account, tolerance_days,
        list(only) if only is not None else None, list(bills) if bills is not None else None)
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
