# ana:description Cancela a fatura de uma ordem de serviço avulsa: estorno do lançamento, dos títulos e das cobranças; a OS volta a concluída
# ana:exposed yes
# ana:category Logística e campo/Serviços em campo
"""Spec 038 (RF-038-08). Only for orders invoiced to the customer (orders of projects are invoiced by the
project: cancel the project invoice instead), while every bill is open and no charge was paid. Parts
used stay consumed (they were used); the invoice can be issued again."""

from ana_lib.util import validation as v

PARAMS = {"order": {"type": "int", "required": True, "label": "OS"},
          "reason": {"type": "str", "required": True, "label": "motivo"}}


def main(order, reason):
    v.require(len((reason or "").strip()) >= 5, "INVALID_PARAMETER", "diga o motivo do cancelamento (fica no histórico)")
    o = ana.sql_one("SELECT id, number, status, project_id, bill_id FROM field.service_order WHERE number = $1 FOR UPDATE", order)
    v.require(o, "SERVICE_ORDER_NOT_FOUND", f"OS {order} não encontrada")
    v.require(o["status"] == "invoiced", "INVALID_STATE", f"a OS {order} não está faturada")
    v.require(not o["project_id"], "PROJECT_ORDER", "OS de projeto é faturada pelo projeto: cancele a fatura do projeto")
    doc = f"OS-{order}"
    bills = ana.sql("SELECT id, status, entry_id FROM finance.bill WHERE (document = $1 OR document LIKE $1 || '/%') "
                    "AND kind = 'receivable' AND status <> 'cancelled' FOR UPDATE", doc)
    v.require(all(b["status"] == "open" for b in bills), "BILL_NOT_OPEN", "há título já baixado: faça uma devolução ao cliente")
    v.require(not ana.sql_value("SELECT count(*) FROM finance.charge WHERE bill_id = ANY($1) AND status = 'paid'", [b["id"] for b in bills]),
              "CHARGE_PAID", "há cobrança paga no gateway: faça uma devolução ao cliente")
    entries = sorted({b["entry_id"] for b in bills if b["entry_id"]})
    for e in entries:
        rev = ana.sql_value("INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
                            f"Cancelamento da fatura da OS {order}: {reason.strip()}"[:200], doc + "-CANC", ana.context.user)
        ana.sql_exec("INSERT INTO finance.journal_line (entry_id, account, debit, credit, cost_center) "
                     "SELECT $2, account, credit, debit, cost_center FROM finance.journal_line WHERE entry_id = $1", e, rev)
    ids = [b["id"] for b in bills]
    ana.sql_exec("UPDATE finance.bill SET status = 'cancelled' WHERE id = ANY($1)", ids)
    ana.sql_exec("UPDATE finance.charge SET status = 'cancelled' WHERE bill_id = ANY($1) AND status IN ('requested', 'issued')", ids)
    ana.sql_exec("DELETE FROM field.invoice_line WHERE order_id = $1", o["id"])
    ana.sql("SELECT set_config('ana.invoice_cancel', $1, true)", str(order))      # the guard lets this order back to "done"
    ana.sql_exec("UPDATE field.service_order SET status = 'done', invoiced_at = NULL, entry_id = NULL, bill_id = NULL WHERE id = $1", o["id"])
    return {"order": order, "bills_cancelled": len(ids)}
