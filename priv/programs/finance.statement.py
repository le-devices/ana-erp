# ana:description Extrato bancário: regras de lançamento para linhas sem título, transferências entre contas próprias e repasses do gateway
# ana:kind library
"""Spec 038 (RF-038-06, 07). Every statement line ends with an entry: a bill settlement (finance.banking),
a posting rule (fee, IOF, yield…), an own transfer (both lines in one entry) or a gateway payout (the
paid charges leave the gateway receivable). Nothing is just ignored."""

from decimal import Decimal

import ana

CENT = Decimal("0.01")


def post_line(line, account, cost_center, memo, rule, user):
    """Bank against the given account, one entry; the line is matched."""
    bank = ana.sql_value("SELECT account FROM finance.bank_account WHERE code = $1", line["bank_account"])
    amount = Decimal(line["amount"])
    entry = ana.sql_value("INSERT INTO finance.journal_entry (entry_date, memo, document, created_by) VALUES ($1, $2, $3, $4) RETURNING id",
                          line["posted_on"], (memo or line.get("description") or "extrato")[:200], f"EXT-{line['id']}", user)
    ana.sql("SELECT set_config('ana.cost_center', $1, true)", cost_center or "")
    ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit) VALUES ($1, $2, $3, $4)",
                  [[entry, bank, amount, 0], [entry, account, 0, amount]] if amount > 0 else
                  [[entry, account, -amount, 0], [entry, bank, 0, -amount]])
    ana.sql_exec("UPDATE finance.bank_statement_line SET status = 'matched', entry_id = $2, matched_by = $3, matched_at = now(), "
                 "rule = $4 WHERE id = $1", line["id"], entry, user, rule)
    return entry


def apply_rules(bank_account, user, exclude=()):
    """Open lines that match an active rule (text found in description or document, direction) get their entry."""
    rules = ana.sql("SELECT id, pattern, direction, account, cost_center, memo FROM finance.statement_rule "
                    "WHERE active AND (bank_account IS NULL OR bank_account = $1) ORDER BY priority, id", bank_account)
    if not rules:
        return 0
    lines = ana.sql("SELECT id, bank_account, posted_on, amount, description, document FROM finance.bank_statement_line "
                    "WHERE bank_account = $1 AND status = 'open' ORDER BY posted_on, id FOR UPDATE SKIP LOCKED", bank_account)
    n = 0
    for l in lines:
        if l["id"] in exclude:            # a line with a bill candidate waits for a person: rules never steal it
            continue
        text = f"{l['description'] or ''} {l['document'] or ''}".lower()
        for r in rules:
            if r["pattern"].lower() in text and (r["direction"] == "any" or (r["direction"] == "in") == (l["amount"] > 0)):
                post_line(l, r["account"], r["cost_center"], r["memo"] or l["description"], f"rule:{r['id']}", user)
                n += 1
                break
    return n


def own_transfers(user):
    """A line out of one own account and the same amount into another (±2 days): one entry, both matched."""
    pairs = ana.sql(
        "SELECT o.id AS out_id, i.id AS in_id, o.amount AS out_amount, i.amount AS in_amount, o.posted_on AS out_day, "
        "  i.posted_on AS in_day, o.bank_account AS out_bank, i.bank_account AS in_bank, "
        "  (SELECT account FROM finance.bank_account WHERE code = o.bank_account) AS out_ledger, "
        "  (SELECT account FROM finance.bank_account WHERE code = i.bank_account) AS in_ledger "
        "FROM finance.bank_statement_line o JOIN finance.bank_statement_line i ON i.amount = -o.amount "
        "  AND i.bank_account <> o.bank_account AND i.posted_on BETWEEN o.posted_on - 2 AND o.posted_on + 2 "
        "WHERE o.status = 'open' AND i.status = 'open' AND o.amount < 0 ORDER BY o.posted_on, o.id")
    used, n = set(), 0
    for p in pairs:
        if p["out_id"] in used or p["in_id"] in used:
            continue
        # Only unambiguous pairs: one candidate on each side.
        alt = [x for x in pairs if (x["out_id"] == p["out_id"] or x["in_id"] == p["in_id"]) and x is not p
               and x["out_id"] not in used and x["in_id"] not in used]
        if alt:
            continue
        amount = -Decimal(p["out_amount"])
        entry = ana.sql_value("INSERT INTO finance.journal_entry (entry_date, memo, document, created_by) VALUES ($1, $2, $3, $4) RETURNING id",
                              p["in_day"], f"Transferência entre contas {p['out_bank']} → {p['in_bank']}", f"TRF-{p['out_id']}-{p['in_id']}", user)
        ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit) VALUES ($1, $2, $3, $4)",
                      [[entry, p["in_ledger"], amount, 0], [entry, p["out_ledger"], 0, amount]])
        ana.sql_exec("UPDATE finance.bank_statement_line SET status = 'matched', entry_id = $2, matched_by = $3, matched_at = now(), "
                     "rule = 'transfer' WHERE id = ANY($1)", [p["out_id"], p["in_id"]], entry, user)
        used |= {p["out_id"], p["in_id"]}
        n += 1
    return n


def gateway_payouts(bank_account, user):
    """A payout (money in) equal to the net of the oldest paid charges of one gateway not yet paid out, up to its date:
    D bank / C gateway receivable; the charges point to the line. Two gateways that fit the same line: a person decides."""
    lines = ana.sql("SELECT id, bank_account, posted_on, amount, description FROM finance.bank_statement_line "
                    "WHERE bank_account = $1 AND status = 'open' AND amount > 0 ORDER BY posted_on, id FOR UPDATE SKIP LOCKED", bank_account)
    if not lines:
        return 0
    pending = ana.sql("SELECT id, connector, net, paid_at::date AS day FROM finance.charge WHERE status = 'paid' AND payout_line_id IS NULL "
                      "AND net IS NOT NULL ORDER BY connector, paid_at, id")
    taken, n = set(), 0
    for l in lines:
        amount = Decimal(l["amount"])
        fits = []
        for conn in sorted({c["connector"] for c in pending}):
            total, take = Decimal(0), []
            for c in pending:
                if c["connector"] != conn or c["id"] in taken or c["day"] > l["posted_on"]:
                    continue
                total += Decimal(c["net"])
                take.append(c["id"])
                if abs(total - amount) < CENT:
                    fits.append((conn, take))
                    break
                if total > amount:
                    break
        if len(fits) != 1:
            continue
        conn, take = fits[0]
        post_line(l, ana.sql_value("SELECT finance.account_for('gateway_receivable')"), None,
                  f"Repasse do gateway {conn} ({len(take)} cobrança(s))", "gateway", user)
        ana.sql_exec("UPDATE finance.charge SET payout_line_id = $2 WHERE id = ANY($1)", take, l["id"])
        taken.update(take)
        n += 1
    return n
