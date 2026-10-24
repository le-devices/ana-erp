# ana:description Aponta deslocamento ou trabalho na OS (idempotente pela chave do app)
# ana:exposed yes
# ana:category Logística e campo/Serviços em campo
"""RF-015-08, RNF-015-02. The same client_key sent twice (intermittent connection) records once."""

from ana_lib.field import common

PARAMS = {
    "order": {"type": "int", "required": True, "label": "OS", "lookup": {"program": "logistics.lookup", "params": {"kind": "service_orders"}}},
    "kind": {"type": "str", "default": "work", "label": "tipo", "choices": [["work", "Trabalho"], ["travel", "Deslocamento"]]},
    "hours": {"type": "decimal", "required": True, "label": "horas"},
    "km": {"type": "decimal", "default": 0, "label": "km (deslocamento)"},
    "technician": {"type": "int", "label": "técnico (vazio = eu)", "lookup": {"program": "logistics.lookup", "params": {"kind": "technicians"}}},
    "note": {"type": "str", "label": "observação"},
    "client_key": {"type": "str", "label": "chave do app (idempotência)"},
}


def main(order, hours, kind="work", km=0, technician=None, note=None, client_key=None):
    if client_key:
        prev = ana.sql_value("SELECT id FROM field.work_log WHERE client_key = $1", client_key)
        if prev:
            return {"id": prev, "repeated": True}
    o = common.order(order, lock=True)
    common.require_open(o)
    tech = technician or common.current_technician()
    if not tech:
        raise ana.Error("TECHNICIAN_NOT_FOUND", "informe o técnico")
    common.technician(tech)
    wid = ana.sql_value("INSERT INTO field.work_log (order_id, employee_id, kind, hours, km, note, client_key, created_by) "
                        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id", o["id"], tech, kind, hours, km or 0, note or "",
                        client_key, ana.context.user)
    common.advance(o, "in_progress" if kind == "work" else "en_route")
    return {"id": wid, "order": o["number"]}
