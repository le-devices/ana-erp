# ana:description Baixa de títulos por extrato ou cobrança: lançamentos em lote
# ana:kind library
"""Settlement of bills from bank statement lines and gateway charges (spec 017).

Receivable: D bank / C customers. Payable: D suppliers / C bank. A difference goes
to interest_received (more than the bills) or bank_fees (less). Everything is
written in batches: one statement per table, whatever the number of lines."""

from decimal import Decimal

import ana

ZERO = Decimal(0)


def bank_ledger(code):
    acc = ana.sql_value("SELECT account FROM finance.bank_account WHERE code = $1 AND active", code)
    if not acc:
        raise ana.Error("BANK_ACCOUNT_NOT_FOUND", f"conta bancária {code} não encontrada")
    return acc


def journal_lines(ledger, amount, bills, difference):
    """[(account_key_or_code, debit, credit)] for one settlement. amount > 0 = money in."""
    out = []
    if amount > 0:
        out.append((ledger, amount, ZERO))
    else:
        out.append((ledger, ZERO, -amount))
    for b in bills:
        key = "customers" if b["kind"] == "receivable" else "suppliers"
        if b["kind"] == "receivable":
            out.append(("@" + key, ZERO, b["amount"]))
        else:
            out.append(("@" + key, b["amount"], ZERO))
    if difference > 0:
        out.append(("@interest_received", ZERO, difference))
    elif difference < 0:
        out.append(("@bank_fees", -difference, ZERO))
    return out


def settle_lines(items, rule, user):
    """items: [{"line": {...id, amount, bank_account, posted_on}, "bills": [{id, kind, amount}], "difference"}].
    Posts one entry per statement line, settles the bills and links everything."""
    if not items:
        return []
    ledgers = {r["code"]: r["account"] for r in ana.sql(
        "SELECT code, account FROM finance.bank_account WHERE code = ANY($1)",
        sorted({i["line"]["bank_account"] for i in items}))}
    entries = {r["document"]: r["id"] for r in ana.sql(
        "INSERT INTO finance.journal_entry (entry_date, memo, document, created_by) "
        "SELECT d, m, doc, $4 FROM unnest($1::date[], $2::text[], $3::text[]) AS x(d, m, doc) RETURNING id, document",
        [i["line"]["posted_on"] for i in items],
        [f"Conciliação bancária — {i['line'].get('description') or 'extrato'}"[:200] for i in items],
        [f"EXT-{i['line']['id']}" for i in items], user)}
    jl, matches, line_rows = [], [], []
    for i in items:
        entry = entries[f"EXT-{i['line']['id']}"]
        for acc, debit, credit in journal_lines(ledgers[i["line"]["bank_account"]], i["line"]["amount"], i["bills"],
                                                i.get("difference", ZERO)):
            jl.append([entry, acc, debit, credit])
        matches += [[i["line"]["id"], b["id"], b["amount"], rule] for b in i["bills"]]
        line_rows.append([i["line"]["id"], entry])
    ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit) "
                  "VALUES ($1, CASE WHEN left($2, 1) = '@' THEN finance.account_for(substr($2, 2)) ELSE $2 END, $3, $4)", jl)
    ana.sql_batch("INSERT INTO finance.bank_match (line_id, bill_id, amount, rule) VALUES ($1, $2, $3, $4)", matches)
    bill_ids = [m[1] for m in matches]
    if bill_ids:
        # Only open bills: a bill settled meanwhile makes the whole batch fail (nothing half done).
        n = ana.sql_exec("UPDATE finance.bill SET status = 'settled' WHERE id = ANY($1) AND status = 'open'", bill_ids)
        if n != len(set(bill_ids)):
            raise ana.Error("BILL_NOT_OPEN", "algum título já foi baixado por outro caminho; refaça a conciliação")
    ana.sql_exec("UPDATE finance.bank_statement_line l SET status = 'matched', entry_id = x.entry, matched_by = $3, "
                 "matched_at = now() FROM unnest($1::bigint[], $2::bigint[]) AS x(id, entry) WHERE l.id = x.id",
                 [r[0] for r in line_rows], [r[1] for r in line_rows], user)
    return line_rows
