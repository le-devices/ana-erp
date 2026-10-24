# ana:description Notas de fornecedor pendentes (diferença acima da tolerância): aceitar com a diferença ou recusar
# ana:exposed yes
# ana:category Compras/Recebimento e notas
"""Spec 038 (RF-038-10, CA-038-12). Accepting posts the difference as purchase price variance; refusing frees
the receipts for a corrected invoice. The person who registered the invoice does not decide it."""

from ana_lib.supply import invoicing as reg

PARAMS = {"id": {"type": "int", "label": "nota"},
          "decision": {"type": "str", "label": "decisão", "choices": [["accept", "Aceitar"], ["reject", "Recusar"]]},
          "reason": {"type": "str", "label": "motivo (recusa)"}}


def main(id=None, decision=None, reason=None):
    if id and decision:
        i = ana.sql_one("SELECT * FROM supply.supplier_invoice WHERE id = $1 FOR UPDATE", id)
        if not i or i["status"] != "pending":
            raise ana.Error("NOT_FOUND", f"nota {id} não está pendente")
        if i["created_by"] == ana.context.user and ana.context.role != "admin":
            raise ana.Error("SELF_APPROVAL", "a nota com diferença é decidida por outra pessoa")
        if decision == "accept":
            return {"id": id, "status": "accepted", "bill": reg.accept(id, ana.context.user)}
        if len((reason or "").strip()) < 3:
            raise ana.Error("INVALID_PARAMETER", "diga o motivo da recusa")
        ana.sql_exec("UPDATE supply.supplier_invoice SET status = 'rejected', reason = $2, decided_by = $3, decided_at = now() WHERE id = $1",
                     id, reason.strip(), ana.context.user)
        ana.sql_exec("UPDATE supply.receipt SET invoice_id = NULL WHERE invoice_id = $1", id)
        return {"id": id, "status": "rejected"}
    rows = ana.sql("SELECT i.id, i.number, p.name AS supplier, o.number AS order_number, i.amount, i.expected, i.difference, i.reason, "
                   "i.created_by, i.created_at FROM supply.supplier_invoice i JOIN base.party p ON p.id = i.supplier_id "
                   "JOIN supply.purchase_order o ON o.id = i.order_id WHERE i.status = 'pending' ORDER BY i.id")
    me = "supply.invoices"
    ana.table([{"nota": r["number"], "fornecedor": r["supplier"], "ordem": r["order_number"], "valor": r["amount"], "recebido": r["expected"],
                "diferença": r["difference"], "registrada por": r["created_by"],
                "_actions": [{"label": "Aceitar", "program": me, "params": {"id": r["id"], "decision": "accept"}, "style": "primary",
                              "confirm": f"Aceitar a nota com diferença de R$ {r['difference']} (variação de preço de compras)?"},
                             {"label": "Recusar", "program": me, "params": {"id": r["id"], "decision": "reject"},
                              "ask": {"reason": {"type": "str", "label": "motivo", "required": True}}}]} for r in rows],
              title="Notas com diferença acima da tolerância")
    return {"pending": len(rows)}
