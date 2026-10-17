# ana:description Cancela a fatura de um pedido de venda: estorno do lançamento, dos títulos e das cobranças, volta do estoque com o mesmo valor
# ana:exposed yes
# ana:command cancelar_fatura
"""Spec 038 (RF-038-08, CA-038-10). Only while every bill of the order is open and no charge was paid.
Never deletes history: a reversal entry, bills and charges cancelled, the goods that left at invoicing
come back at the cost they left (the database posts D inventory / C cost of goods sold), the order is
open again. Goods shipped before the invoice (stock out at shipment) stay with the shipment."""

from ana_lib.util import validation as v

PARAMS = {"number": {"type": "int", "required": True, "label": "pedido", "lookup": {"program": "sales.lookup", "params": {"kind": "invoiced"}}},
          "reason": {"type": "str", "required": True, "label": "motivo"}}


def main(number, reason):
    v.require(len((reason or "").strip()) >= 5, "INVALID_PARAMETER", "diga o motivo do cancelamento (fica no histórico)")
    o = ana.sql_one("SELECT id, number, status, warehouse_id FROM sales.sales_order WHERE number = $1 FOR UPDATE", number)
    v.require(o, "ORDER_NOT_FOUND", f"pedido {number} não encontrado")
    v.require(o["status"] == "INVOICED", "INVALID_STATE", f"o pedido {number} não está faturado")
    doc = f"ORD-{number}"
    bills = ana.sql("SELECT id, status, entry_id FROM finance.bill WHERE (document = $1 OR document LIKE $1 || '/%') "
                    "AND kind = 'receivable' AND status <> 'cancelled' FOR UPDATE", doc)
    v.require(all(b["status"] == "open" for b in bills), "BILL_NOT_OPEN",
              "há título já baixado: estorne o recebimento antes ou faça uma devolução")
    paid = ana.sql_value("SELECT count(*) FROM finance.charge c WHERE c.bill_id = ANY($1) AND c.status = 'paid'", [b["id"] for b in bills])
    v.require(not paid, "CHARGE_PAID", "há cobrança paga no gateway: faça uma devolução ao cliente")
    cancel_document(doc, f"Cancelamento da fatura do pedido {number}: {reason.strip()}", bills)
    # Goods that left at invoicing come back at the same cost.
    moved = ana.sql("SELECT product_id, warehouse_id, quantity, unit_cost FROM inventory.stock_movement "
                    "WHERE document = $1 AND reason = 'sale' AND quantity < 0", doc)
    if moved:
        ana.sql_batch("INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, created_by, reason, unit_cost) "
                      "VALUES ($1, $2, $3, 'in', $4, $5, 'sale', $6)",
                      [[m["product_id"], m["warehouse_id"], -m["quantity"], doc + "-CANC", ana.context.user, m["unit_cost"]] for m in moved])
    ana.sql_exec("UPDATE sales.sales_order SET status = 'OPEN', invoiced_at = NULL WHERE id = $1", o["id"])
    ana.log(f"fatura do pedido {number} cancelada: {reason.strip()}")
    return {"order": number, "bills_cancelled": len(bills), "stock_returned": len(moved)}


def cancel_document(doc, memo, bills):
    """Reverses every entry of the document's invoice (lines swapped), cancels bills and pending charges."""
    entries = sorted({b["entry_id"] for b in bills if b["entry_id"]})
    for e in entries:
        rev = ana.sql_value("INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
                            memo[:200], doc + "-CANC", ana.context.user)
        ana.sql_exec("INSERT INTO finance.journal_line (entry_id, account, debit, credit, cost_center) "
                     "SELECT $2, account, credit, debit, cost_center FROM finance.journal_line WHERE entry_id = $1", e, rev)
    ids = [b["id"] for b in bills]
    ana.sql_exec("UPDATE finance.bill SET status = 'cancelled' WHERE id = ANY($1)", ids)
    ana.sql_exec("UPDATE finance.charge SET status = 'cancelled' WHERE bill_id = ANY($1) AND status IN ('requested', 'issued')", ids)
