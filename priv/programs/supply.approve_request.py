# ana:description Aprova ou recusa solicitação de compra dentro da alçada
# ana:exposed yes
# ana:command aprovar
"""RF-013-03. Whoever requested does not approve; above the user's limit (role or access
group, supply.approval_limit) another approver is required. Draft requests are submitted first."""

from ana_lib.supply import common

PARAMS = {
    "request": {"type": "int", "required": True, "label": "solicitação", "lookup": {"program": "supply.lookup", "params": {"kind": "requests"}}},
    "decision": {"type": "str", "default": "approve", "label": "decisão", "choices": [["approve", "Aprovar"], ["reject", "Recusar"]]},
    "reason": {"type": "str", "label": "motivo da recusa"},
}


def main(request, decision="approve", reason=None):
    r = ana.sql_one("SELECT id, number, requester, status, total FROM supply.purchase_request WHERE number = $1 FOR UPDATE",
                    request)
    if not r:
        raise ana.Error("REQUEST_NOT_FOUND", f"solicitação {request} não encontrada")
    if r["requester"] == ana.context.user:
        raise ana.Error("SELF_APPROVAL", "quem solicita não aprova a própria solicitação")
    if r["status"] == "draft":
        ana.sql_exec("UPDATE supply.purchase_request SET status = 'submitted' WHERE id = $1", r["id"])
    elif r["status"] != "submitted":
        raise ana.Error("INVALID_STATE", f"solicitação {r['number']} não está aguardando aprovação")
    if decision == "reject":
        if not reason:
            raise ana.Error("INVALID_PARAMETER", "informe o motivo da recusa")
        ana.sql_exec("UPDATE supply.purchase_request SET status = 'rejected', approved_by = $2, approved_at = now(), "
                     "rejection_reason = $3 WHERE id = $1", r["id"], ana.context.user, reason)
        return {"number": r["number"], "status": "rejected"}
    if decision != "approve":
        raise ana.Error("INVALID_PARAMETER", "decisão deve ser approve ou reject")
    ana.extend("before_approve_purchase", {"number": r["number"], "requester": r["requester"], "total": r["total"]})   # spec 009
    limit = common.approval_limit()
    if limit is not None and r["total"] > limit:
        raise ana.Error("ABOVE_APPROVAL_LIMIT",
                        f"valor R$ {r['total']} acima da sua alçada (R$ {limit}); peça a um aprovador com limite maior",
                        {"total": r["total"], "limit": limit})
    ana.sql_exec("UPDATE supply.purchase_request SET status = 'approved', approved_by = $2, approved_at = now() "
                 "WHERE id = $1", r["id"], ana.context.user)
    ana.actions([{"label": "Gerar ordens de compra", "program": "supply.create_orders", "params": {"requests": [r["number"]]}}])
    ana.extend("after_approve_purchase", {"number": r["number"], "status": "approved", "total": r["total"]})
    return {"number": r["number"], "status": "approved", "total": r["total"]}
