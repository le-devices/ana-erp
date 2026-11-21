# ana:description Aceite do cliente: conclui a OS (exige o checklist obrigatório respondido)
# ana:exposed yes
# ana:category Logística e campo/Serviços em campo
"""RF-015-08. Name, document and time of whoever accepted on site; the order becomes done."""

from ana_lib.field import common
from ana_lib.docs import pdfs

PARAMS = {
    "order": {"type": "int", "required": True, "label": "OS", "lookup": {"program": "logistics.lookup", "params": {"kind": "service_orders"}}},
    "signed_by": {"type": "str", "required": True, "label": "aceite de (nome)"},
    "document": {"type": "str", "label": "documento"},
    "notes": {"type": "str", "label": "observações"},
}


def main(order, signed_by, document=None, notes=None):
    o = common.order(order, lock=True)
    if o["status"] == "done":
        return {"order": o["number"], "status": "done", "repeated": True}
    common.require_open(o)
    if not ana.sql_value("SELECT count(*) FROM field.work_log WHERE order_id = $1 AND kind = 'work'", o["id"]):
        raise ana.Error("NO_WORK_LOGGED", "aponte as horas de trabalho antes do aceite")
    missing = ana.sql_value("SELECT count(*) FROM field.checklist_template t LEFT JOIN field.checklist_answer a "
                            "ON a.order_id = $1 AND a.item = t.item WHERE t.service_product_id = $2 AND t.required "
                            "AND (a.answer IS NULL OR a.answer = '')", o["id"], o["service_product_id"])
    if missing:
        raise ana.Error("CHECKLIST_INCOMPLETE", f"{missing} pergunta(s) obrigatória(s) do checklist sem resposta")
    ana.sql_exec("INSERT INTO field.sign_off (order_id, signed_by, document, notes, recorded_by) VALUES ($1, $2, $3, $4, $5)",
                 o["id"], signed_by.strip(), document, notes or "", ana.context.user)
    common.advance(o, "in_progress")
    ana.sql_exec("UPDATE field.service_order SET status = 'done', done_at = now() WHERE id = $1", o["id"])
    ana.sql_exec("UPDATE field.assignment SET status = 'done' WHERE order_id = $1 AND status = 'planned'", o["id"])
    pdfs.publish_quietly("service_order", o["number"])  # spec 037: service report
    return {"order": o["number"], "status": "done"}
