# ana:description Fornecedor confirma ou altera o prazo de entrega de uma ordem de compra
# ana:exposed yes
# ana:category Compras/Ordens de compra
"""RF-013-10: exposed for integration (e.g. a supplier portal through a robot key).
Without `line`, applies to every line still pending."""

import datetime

PARAMS = {
    "order": {"type": "int", "required": True, "label": "ordem de compra", "lookup": {"program": "supply.lookup", "params": {"kind": "orders"}}},
    "promised_date": {"type": "date", "required": True, "label": "nova data prometida"},
    "line": {"type": "int", "label": "linha (vazio = todas as pendentes)",
             "lookup": {"program": "supply.lookup", "params": {"kind": "order_lines"}, "depends": ["order"]}},
}


def main(order, promised_date, line=None):
    o = ana.sql_one("SELECT id, number, status FROM supply.purchase_order WHERE number = $1 FOR UPDATE", order)
    if not o:
        raise ana.Error("ORDER_NOT_FOUND", f"ordem {order} não encontrada")
    if o["status"] not in ("sent", "partially_received"):
        raise ana.Error("INVALID_STATE", f"ordem {o['number']} não está aguardando entrega")
    if promised_date < datetime.date.today():
        raise ana.Error("INVALID_DATE", "a data prometida já passou")
    n = ana.sql_exec("UPDATE supply.purchase_order_line SET promised_date = $2 WHERE order_id = $1 "
                     "AND received_qty < quantity AND ($3::int IS NULL OR line = $3)", o["id"], promised_date, line)
    if not n:
        raise ana.Error("NOTHING_TO_CONFIRM", "nenhuma linha pendente para confirmar")
    return {"order": o["number"], "lines": n, "promised_date": promised_date}
