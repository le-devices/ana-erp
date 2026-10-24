# ana:description Bloqueia ou desbloqueia cliente, ou libera um pedido específico de um cliente bloqueado
# ana:exposed yes
# ana:role developer
# ana:category Financeiro/Crédito e condições
"""RF-031-05, CA-031-04. Every action records who, when and why. A release is used once (the
next order or invoicing of that customer, or of the given order)."""

import datetime

PARAMS = {
    "customer": {"type": "int", "required": True, "label": "cliente", "lookup": {"program": "sales.lookup", "params": {"kind": "customers"}}},
    "action": {"type": "str", "required": True, "label": "ação",
               "choices": [["block", "Bloquear"], ["unblock", "Desbloquear"], ["release_order", "Liberar um pedido"],
                           ["release_invoice", "Liberar um faturamento"], ["policy", "Política geral de crédito"]]},
    "reason": {"type": "str", "required": True, "label": "motivo"},
    "until": {"type": "date", "label": "bloqueado até (vazio = até desbloquear)"},
    "order": {"type": "int", "label": "pedido (liberação)", "lookup": {"program": "sales.lookup", "params": {"kind": "orders"}}},
    "auto_block": {"type": "bool", "label": "política: bloqueio automático por atraso"},
    "grace_days": {"type": "int", "label": "política: tolerância (dias)"},
}


def main(customer, action, reason, until=None, order=None, auto_block=None, grace_days=None):
    if len((reason or "").strip()) < 3:
        raise ana.Error("INVALID_PARAMETER", "explique o motivo")
    if action == "policy":
        ana.sql_exec("UPDATE finance.credit_policy SET auto_block = COALESCE($1, auto_block), grace_days = COALESCE($2, grace_days) "
                     "WHERE id = 1", auto_block, grace_days)
        ana.log(f"política de crédito alterada: {reason}")
        return {"policy": ana.sql_one("SELECT auto_block, grace_days FROM finance.credit_policy WHERE id = 1")}
    if not ana.sql_value("SELECT count(*) FROM base.party WHERE id = $1", customer):
        raise ana.Error("CUSTOMER_NOT_FOUND", f"cliente {customer} não encontrado")
    if action == "block":
        if until and until < datetime.date.today():
            raise ana.Error("INVALID_DATE", "a data final já passou")
        bid = ana.sql_value("INSERT INTO finance.credit_block (party_id, reason, until, blocked_by) VALUES ($1, $2, $3, $4) RETURNING id",
                            customer, reason.strip(), until, ana.context.user)
        return {"customer": customer, "block": bid, "status": "blocked"}
    if action == "unblock":
        n = ana.sql_exec("UPDATE finance.credit_block SET released_by = $2, released_at = now(), release_reason = $3 "
                         "WHERE party_id = $1 AND released_at IS NULL", customer, ana.context.user, reason.strip())
        st = ana.sql_one("SELECT blocked, reason FROM finance.credit_status($1, 0)", customer)
        return {"customer": customer, "released_blocks": n, "still_blocked": st["blocked"], "reason": st["reason"]}
    if action in ("release_order", "release_invoice"):
        oid = None
        if order:
            oid = ana.sql_value("SELECT id FROM sales.sales_order WHERE number = $1 AND customer_id = $2", order, customer)
            if not oid:
                raise ana.Error("ORDER_NOT_FOUND", f"pedido {order} não é deste cliente")
        rid = ana.sql_value("INSERT INTO finance.credit_release (party_id, sales_order_id, scope, reason, granted_by) "
                            "VALUES ($1, $2, $3, $4, $5) RETURNING id", customer, oid,
                            "order" if action == "release_order" else "invoice", reason.strip(), ana.context.user)
        return {"customer": customer, "release": rid}
    raise ana.Error("INVALID_PARAMETER", f"ação desconhecida: {action}")
