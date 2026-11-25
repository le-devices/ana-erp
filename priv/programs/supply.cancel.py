# ana:description Cancela solicitação ou ordem de compra
# ana:exposed yes
# ana:category Compras/Solicitações
# ana:confirm A solicitação ou ordem de compra é cancelada (numa ordem com recebimento parcial, só o que falta). Não há desfazer: para comprar, crie outra.
"""Requests: the requester or an admin, before ordering. Orders: an admin or whoever created
them; an order partly received keeps what came and only the rest is cancelled."""

from ana_lib.supply import common

PARAMS = {
    "kind": {"type": "str", "required": True, "label": "o quê", "choices": [["request", "Solicitação"], ["order", "Ordem de compra"]]},
    "number": {"type": "int", "required": True, "label": "número"},
    "reason": {"type": "str", "required": True, "label": "motivo"},
}


def main(kind, number, reason):
    if kind == "request":
        r = ana.sql_one("SELECT id, requester, status FROM supply.purchase_request WHERE number = $1 FOR UPDATE", number)
        if not r:
            raise ana.Error("REQUEST_NOT_FOUND", f"solicitação {number} não encontrada")
        if r["requester"] != ana.context.user and not common.is_admin():
            raise ana.Error("FORBIDDEN", "só quem solicitou ou um administrador")
        ana.sql_exec("UPDATE supply.purchase_request SET status = 'cancelled', rejection_reason = $2 WHERE id = $1",
                     r["id"], reason)
    elif kind == "order":
        o = ana.sql_one("SELECT id, created_by FROM supply.purchase_order WHERE number = $1 FOR UPDATE", number)
        if not o:
            raise ana.Error("ORDER_NOT_FOUND", f"ordem {number} não encontrada")
        if o["created_by"] != ana.context.user and not common.is_admin():
            raise ana.Error("FORBIDDEN", "só quem criou a ordem ou um administrador")
        ana.sql_exec("UPDATE supply.purchase_order SET status = 'cancelled', "
                     "notes = concat_ws(E'\\n', notes, 'Cancelada: ' || $2) WHERE id = $1", o["id"], reason)
    else:
        raise ana.Error("INVALID_PARAMETER", "kind deve ser request ou order")
    return {"kind": kind, "number": number, "status": "cancelled"}
