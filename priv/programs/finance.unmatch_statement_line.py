# ana:description Desfaz a conciliação de uma linha do extrato (estorna o lançamento e reabre os títulos)
# ana:exposed yes
"""RF-017-07. The settlement entry is reversed (never deleted); a line only linked to a
gateway payment just loses the link."""

PARAMS = {
    "line": {"type": "int", "required": True, "label": "linha do extrato"},
    "reason": {"type": "str", "required": True, "label": "motivo"},
}


def main(line, reason):
    l = ana.sql_one("SELECT id, status, entry_id FROM finance.bank_statement_line WHERE id = $1 FOR UPDATE", line)
    if not l or l["status"] == "open":
        raise ana.Error("LINE_NOT_MATCHED", f"linha {line} não está conciliada")
    own = ana.sql_value("SELECT count(*) FROM finance.journal_entry WHERE id = $1 AND document = $2",
                        l["entry_id"], f"EXT-{line}") if l["entry_id"] else 0
    if own:
        rev = ana.sql_value("INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
                            f"Estorno de conciliação: {reason}"[:200], f"EXT-{line}-REV", ana.context.user)
        ana.sql_exec("INSERT INTO finance.journal_line (entry_id, account, debit, credit, cost_center) "
                     "SELECT $2, account, credit, debit, cost_center FROM finance.journal_line WHERE entry_id = $1",
                     l["entry_id"], rev)
        ana.sql_exec("UPDATE finance.bill SET status = 'open' WHERE id IN (SELECT bill_id FROM finance.bank_match "
                     "WHERE line_id = $1) AND status = 'settled'", line)
    ana.sql_exec("DELETE FROM finance.bank_match WHERE line_id = $1", line)
    ana.sql_exec("UPDATE finance.bank_statement_line SET status = 'open', entry_id = NULL, matched_by = NULL, "
                 "matched_at = NULL WHERE id = $1", line)
    return {"line": line, "status": "open", "reversed": bool(own)}
