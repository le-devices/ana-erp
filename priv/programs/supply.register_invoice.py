# ana:description Registra a nota do fornecedor e a confronta com o recebido (pedido × recebimento × nota): dentro da tolerância vira título; fora, fica pendente
# ana:exposed yes
# ana:command nota_fornecedor
# ana:category Compras/Recebimento e notas
"""Spec 038 (RF-038-10, CA-038-12). For supplier_invoice = 'match'. Expected = what was received and not yet
invoiced on the order. Within the tolerance: D goods received (expected) ± purchase price variance / C
suppliers (the invoice) and the payable bill; above it: pending with the reason (supply.invoices decides)."""

import datetime
from decimal import Decimal

from ana_lib.supply import invoicing
from ana_lib.util import validation as v

PARAMS = {"order": {"type": "int", "required": True, "label": "ordem de compra", "lookup": {"program": "supply.lookup", "params": {"kind": "orders"}}},
          "number": {"type": "str", "required": True, "label": "número da nota"},
          "amount": {"type": "decimal", "required": True, "label": "valor da nota"},
          "due_date": {"type": "date", "label": "vencimento (vazio = prazo da ordem)"}}


def main(order, number, amount, due_date=None):
    o = ana.sql_one("SELECT id, number, supplier_id, payment_days FROM supply.purchase_order WHERE number = $1 FOR UPDATE", order)
    v.require(o, "ORDER_NOT_FOUND", f"ordem {order} não encontrada")
    v.require(amount > 0, "INVALID_VALUE", "valor da nota deve ser positivo")
    receipts = ana.sql("SELECT id, total FROM supply.receipt WHERE order_id = $1 AND bill_id IS NULL AND invoice_id IS NULL AND total > 0 "
                       "ORDER BY id FOR UPDATE", o["id"])
    v.require(receipts, "NOTHING_RECEIVED", "não há recebimento desta ordem esperando nota (receba antes ou confira a ordem)")
    expected = sum((Decimal(r["total"]) for r in receipts), Decimal(0))
    pol = ana.sql_one("SELECT invoice_tolerance_pct, invoice_tolerance_abs FROM supply.policy WHERE id = 1")
    tol = max(Decimal(pol["invoice_tolerance_abs"]), (expected * Decimal(pol["invoice_tolerance_pct"]) / 100).quantize(Decimal("0.01")))
    diff = Decimal(amount) - expected
    due = due_date or (datetime.date.today() + datetime.timedelta(days=o["payment_days"]))
    inv = ana.sql_value("INSERT INTO supply.supplier_invoice (order_id, supplier_id, number, amount, expected, difference, due_date, receipts, "
                        "  created_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id", o["id"], o["supplier_id"], number.strip(),
                        amount, expected, diff, due, [r["id"] for r in receipts], ana.context.user)
    ana.sql_exec("UPDATE supply.receipt SET invoice_id = $2 WHERE id = ANY($1)", [r["id"] for r in receipts], inv)
    if abs(diff) <= tol:
        bill = invoicing.accept(inv, ana.context.user)
        return {"invoice": inv, "status": "accepted", "expected": expected, "difference": diff, "bill": bill}
    reason = f"nota R$ {amount} × recebido R$ {expected}: diferença de R$ {diff} acima da tolerância de R$ {tol}"
    ana.sql_exec("UPDATE supply.supplier_invoice SET reason = $2 WHERE id = $1", inv, reason)
    ana.actions([{"label": "Decidir as notas pendentes", "program": "supply.invoices", "open": True}], title="Próximo passo")
    return {"invoice": inv, "status": "pending", "expected": expected, "difference": diff, "reason": reason}
