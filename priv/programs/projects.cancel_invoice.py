# ana:description Cancela fatura de serviço (estorno contábil e devolução das origens)
# ana:exposed yes
# ana:command cancelinvoice
# ana:category Projetos/Faturamento e custos
# ana:confirm A fatura de serviço é estornada na contabilidade e as horas, despesas e marcos voltam a faturar. O histórico fica; a fatura pode ser emitida de novo.
"""RF-008-13: only while the bill is still open. Posts a reversal entry
(never deletes accounting history) and returns sources to their prior state."""

from ana_lib.projects import access

PARAMS = {
    "number": {"type": "int", "required": True, "label": "fatura (número)"},
    "reason": {"type": "str", "required": True, "label": "motivo"},
}


def main(number, reason):
    inv = ana.sql_one(
        "SELECT i.id, i.number, i.project_id, i.customer_id, i.issue_date, i.through_date, i.total, "
        "i.service_tax_rate, i.service_tax_amount, i.service_tax_withheld, i.net_amount, i.status, "
        "i.bill_id, i.entry_id, i.reversal_entry_id, i.created_by, i.created_at, p.code AS project_code FROM projects.invoice i "
        "JOIN projects.project p ON p.id = i.project_id WHERE i.number = $1 FOR UPDATE OF i", number)
    if not inv:
        raise ana.Error("INVOICE_NOT_FOUND", f"fatura {number} não encontrada")
    access.require_manager(access.project(inv["project_code"]))
    if inv["status"] != "issued":
        raise ana.Error("INVOICE_CANCELLED", f"fatura {number} já está cancelada")
    if len(reason.strip()) < 3:
        raise ana.Error("REASON_REQUIRED", "informe o motivo do cancelamento")
    n = ana.sql_exec("UPDATE finance.bill SET status = 'cancelled' WHERE id = $1 AND status = 'open'",
                     inv["bill_id"])
    if n != 1:
        raise ana.Error("BILL_SETTLED", "o título já foi liquidado; cancele a liquidação antes")

    reversal = ana.sql_value(
        "INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
        f"Estorno da fatura {number}: {reason.strip()}", f"INV-{number}-REV", ana.context.user)
    ana.sql_exec(
        "INSERT INTO finance.journal_line (entry_id, account, debit, credit, cost_center) "
        "SELECT $1, account, credit, debit, cost_center FROM finance.journal_line WHERE entry_id = $2",
        reversal, inv["entry_id"])

    ana.sql_exec("UPDATE projects.time_entry SET status = 'approved', invoice_id = NULL WHERE invoice_id = $1",
                 inv["id"])
    ana.sql_exec("UPDATE projects.expense SET status = 'posted', invoice_id = NULL WHERE invoice_id = $1",
                 inv["id"])
    ana.sql_exec("UPDATE projects.milestone SET status = 'completed', invoice_id = NULL WHERE invoice_id = $1",
                 inv["id"])
    ana.sql_exec("UPDATE projects.invoice SET status = 'cancelled', reversal_entry_id = $2 WHERE id = $1",
                 inv["id"], reversal)
    return {"number": number, "status": "cancelled", "reversal_entry": reversal}
