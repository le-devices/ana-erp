# ana:description Baixa de títulos por extrato ou cobrança: valores exatos (residual, crédito), tolerância e compensação automática
# ana:kind library
"""Settlement of bills from bank statement lines and gateway charges (spec 017; exact, spec 038).

Each bill is settled against its own control account (customers, suppliers, customer credits…).
What was paid is applied to the bills oldest first:
  - a difference within the tolerance goes to interest received (more) or bank fees (less);
  - paying less than that leaves the rest open in a residual bill of the same document (never a fee);
  - paying more than that becomes a credit of the customer (or an advance to the supplier).
Credits are then offset against the party's open bills when the policy says so (finance.offset)."""

import datetime
from decimal import Decimal

import ana

ZERO = Decimal(0)
CENT = Decimal("0.01")
CREDIT_FOR = {"receivable": ("payable", "customer_credits"), "payable": ("receivable", "supplier_advances")}


def bank_ledger(code):
    acc = ana.sql_value("SELECT account FROM finance.bank_account WHERE code = $1 AND active", code)
    if not acc:
        raise ana.Error("BANK_ACCOUNT_NOT_FOUND", f"conta bancária {code} não encontrada")
    return acc


def policy():
    return ana.sql_one("SELECT tolerance, auto_offset FROM finance.settlement_policy WHERE id = 1") or {
        "tolerance": Decimal("1.00"), "auto_offset": True}


def bills_by_id(ids):
    return {b["id"]: b for b in ana.sql(
        "SELECT id, kind, amount, account, party_id, document, due_date, entry_id, status FROM finance.bill "
        "WHERE id = ANY($1) ORDER BY id FOR UPDATE", sorted(set(ids)))}


def allocate(bills, paid, tolerance):
    """Applies `paid` to bills (oldest due first). Returns (applied [(bill, amount)], residuals [(bill, rest)],
    untouched [bill], adjustment (within tolerance; + interest, − fee), excess (beyond tolerance))."""
    order = sorted(bills, key=lambda b: (b.get("due_date") or datetime.date.max, b["id"]))
    due = sum((Decimal(b["amount"]) for b in order), ZERO)
    diff = paid - due
    if abs(diff) <= tolerance:
        return [(b, Decimal(b["amount"])) for b in order], [], [], diff, ZERO
    if diff > 0:
        return [(b, Decimal(b["amount"])) for b in order], [], [], ZERO, diff
    applied, residuals, untouched, left = [], [], [], paid
    for b in order:
        amount = Decimal(b["amount"])
        if left <= 0:
            untouched.append(b)
        elif left >= amount:
            applied.append((b, amount))
            left -= amount
        else:
            applied.append((b, left))
            residuals.append((b, amount - left))
            left = ZERO
    return applied, residuals, untouched, ZERO, ZERO


def journal_lines(ledger, amount, applied, adjustment, excess, kind):
    """[(account_code_or_@key, debit, credit)] for one settlement. amount > 0 = money in."""
    out = [(ledger, amount, ZERO) if amount > 0 else (ledger, ZERO, -amount)]
    for b, value in applied:
        out.append((b["account"], ZERO, value) if b["kind"] == "receivable" else (b["account"], value, ZERO))
    if adjustment > 0:
        out.append(("@interest_received", ZERO, adjustment))
    elif adjustment < 0:
        out.append(("@bank_fees", -adjustment, ZERO))
    if excess > 0:
        out.append(("@customer_credits", ZERO, excess) if kind == "receivable" else ("@supplier_advances", excess, ZERO))
    return out


def residual(bill_id, rest):
    """The unpaid part of a bill stays open: same party, account and entry, document with /R."""
    return ana.sql_value(
        "INSERT INTO finance.bill (kind, party_id, document, due_date, amount, entry_id, account, parent_bill_id, installment, "
        "  installments, payment_method, payment_term) "
        "SELECT kind, party_id, left(document || '/R', 120), due_date, $2, entry_id, account, id, installment, installments, "
        "  payment_method, payment_term FROM finance.bill WHERE id = $1 RETURNING id", bill_id, rest)


def credit_bill(kind, party, document, amount, entry):
    """Paid more than owed: a credit of the customer (or an advance to the supplier), to be offset or refunded."""
    ckind, key = CREDIT_FOR[kind]
    return ana.sql_value(
        "INSERT INTO finance.bill (kind, party_id, document, due_date, amount, entry_id, account) "
        "VALUES ($1, $2, $3, current_date + 30, $4, $5, finance.account_for($6)) RETURNING id",
        ckind, party, document, amount, entry, key)


def settle_lines(items, rule, user):
    """items: [{"line": {...id, amount, bank_account, posted_on, description}, "bills": [{id, kind, amount, account, …}]}].
    One entry per statement line; bills settled exactly; residuals and credits created; offsets applied."""
    if not items:
        return []
    tol = Decimal(policy()["tolerance"])
    ledgers = {r["code"]: r["account"] for r in ana.sql(
        "SELECT code, account FROM finance.bank_account WHERE code = ANY($1)", sorted({i["line"]["bank_account"] for i in items}))}
    full = bills_by_id([b["id"] for i in items for b in i["bills"]])
    entries = {r["document"]: r["id"] for r in ana.sql(
        "INSERT INTO finance.journal_entry (entry_date, memo, document, created_by) "
        "SELECT d, m, doc, $4 FROM unnest($1::date[], $2::text[], $3::text[]) AS x(d, m, doc) RETURNING id, document",
        [i["line"]["posted_on"] for i in items],
        [f"Conciliação bancária — {i['line'].get('description') or 'extrato'}"[:200] for i in items],
        [f"EXT-{i['line']['id']}" for i in items], user)}
    jl, matches, line_rows, settle, parties, report = [], [], [], [], set(), []
    for i in items:
        line = i["line"]
        entry = entries[f"EXT-{line['id']}"]
        bills = [full[b["id"]] for b in i["bills"]]
        kind = bills[0]["kind"]
        paid = abs(Decimal(line["amount"]))
        applied, residuals, untouched, adjustment, excess = allocate(bills, paid, tol)
        for acc, debit, credit in journal_lines(ledgers[line["bank_account"]], Decimal(line["amount"]), applied, adjustment, excess, kind):
            jl.append([entry, acc, debit, credit])
        matches += [[line["id"], b["id"], value, rule] for b, value in applied]
        settle += [b["id"] for b, _ in applied]
        line_rows.append([line["id"], entry])
        for b, rest in residuals:
            report.append({"bill": b["id"], "residual": residual(b["id"], rest), "open": rest})
        if excess > 0:
            report.append({"credit": credit_bill(kind, bills[0]["party_id"], f"CRED-EXT-{line['id']}", excess, entry), "amount": excess})
        parties.add(bills[0]["party_id"])
        if untouched:
            report.append({"untouched": [b["id"] for b in untouched]})
    ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit) "
                  "VALUES ($1, CASE WHEN left($2, 1) = '@' THEN finance.account_for(substr($2, 2)) ELSE $2 END, $3, $4)", jl)
    ana.sql_batch("INSERT INTO finance.bank_match (line_id, bill_id, amount, rule) VALUES ($1, $2, $3, $4)", matches)
    if settle:
        # Only open bills: a bill settled meanwhile makes the whole batch fail (nothing half done).
        n = ana.sql_exec("UPDATE finance.bill SET status = 'settled' WHERE id = ANY($1) AND status = 'open'", settle)
        if n != len(set(settle)):
            raise ana.Error("BILL_NOT_OPEN", "algum título já foi baixado por outro caminho; refaça a conciliação")
    ana.sql_exec("UPDATE finance.bank_statement_line l SET status = 'matched', entry_id = x.entry, matched_by = $3, "
                 "matched_at = now(), rule = COALESCE(l.rule, $4) FROM unnest($1::bigint[], $2::bigint[]) AS x(id, entry) WHERE l.id = x.id",
                 [r[0] for r in line_rows], [r[1] for r in line_rows], user, rule)
    if policy()["auto_offset"]:
        for p in sorted(parties):
            offset(p, user)
    settle_lines.last_report = report
    return line_rows


settle_lines.last_report = []


# ---------------------------------------------------------------- offsetting (RF-038-05, L-13)
PAIRS = [
    # (credit bills: kind, account key) against (debit bills: kind, account key)
    (("payable", "customer_credits"), ("receivable", "customers")),
    (("receivable", "supplier_credits"), ("payable", "suppliers")),
    (("receivable", "supplier_advances"), ("payable", "suppliers")),
]


def offset(party_id, user):
    """A party's credits settle its open bills, oldest first, in one entry per pair. Returns the offsets made."""
    made = []
    for (ck, cacc), (dk, dacc) in PAIRS:
        credits = ana.sql("SELECT id, amount, kind, account, due_date FROM finance.bill WHERE party_id = $1 AND kind = $2 "
                          "AND account = finance.account_for($3) AND status = 'open' ORDER BY due_date, id FOR UPDATE",
                          party_id, ck, cacc)
        debits = ana.sql("SELECT id, amount, kind, account, due_date FROM finance.bill WHERE party_id = $1 AND kind = $2 "
                         "AND account = finance.account_for($3) AND status = 'open' ORDER BY due_date, id FOR UPDATE",
                         party_id, dk, dacc)
        ci = di = 0
        crest = Decimal(credits[0]["amount"]) if credits else ZERO
        drest = Decimal(debits[0]["amount"]) if debits else ZERO
        while ci < len(credits) and di < len(debits):
            c, d = credits[ci], debits[di]
            amount = min(crest, drest)
            entry = ana.sql_value("INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
                                  "Compensação de crédito com título em aberto", f"COMP-{c['id']}-{d['id']}", user)
            # A credit bill on the customer side is a liability (debit to use it); on the supplier side, an asset.
            ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit) VALUES ($1, $2, $3, $4)",
                          [[entry, c["account"], amount, 0], [entry, d["account"], 0, amount]] if ck == "payable" else
                          [[entry, d["account"], amount, 0], [entry, c["account"], 0, amount]])
            ana.sql_exec("INSERT INTO finance.offset (party_id, credit_bill, debit_bill, amount, entry_id, created_by) "
                         "VALUES ($1, $2, $3, $4, $5, $6)", party_id, c["id"], d["id"], amount, entry, user)
            made.append({"credit": c["id"], "debit": d["id"], "amount": amount})
            crest -= amount
            drest -= amount
            for b, rest in ((c, crest), (d, drest)):
                ana.sql_exec("UPDATE finance.bill SET status = 'settled' WHERE id = $1", b["id"])
                if rest > 0:
                    nid = residual(b["id"], rest)
                    if b is c:
                        credits[ci] = {**c, "id": nid, "amount": rest}
                    else:
                        debits[di] = {**d, "id": nid, "amount": rest}
            if crest <= 0:
                ci += 1
                crest = Decimal(credits[ci]["amount"]) if ci < len(credits) else ZERO
            if drest <= 0:
                di += 1
                drest = Decimal(debits[di]["amount"]) if di < len(debits) else ZERO
    return made
