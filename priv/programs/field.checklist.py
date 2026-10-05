# ana:description Checklist da OS (perguntas do serviço): consultar ou responder
# ana:exposed yes
"""RF-015-08. Without answers, lists the questions of the service and what was answered."""

from ana_lib.field import common

PARAMS = {
    "order": {"type": "int", "required": True, "label": "OS"},
    "answers": {"type": "list", "label": "respostas", "help": '[{"item": 1, "answer": "ok"}]'},
}


def main(order, answers=None):
    o = common.order(order, lock=bool(answers))
    if answers:
        common.require_open(o)
        ana.sql_exec("INSERT INTO field.checklist_answer (order_id, item, answer, answered_by) "
                     "SELECT $1, i, a, $4 FROM unnest($2::int[], $3::text[]) AS x(i, a) "
                     "ON CONFLICT (order_id, item) DO UPDATE SET answer = EXCLUDED.answer, answered_by = EXCLUDED.answered_by, "
                     "answered_at = now()", o["id"], [int(a["item"]) for a in answers], [str(a["answer"]) for a in answers],
                     ana.context.user)
    rows = ana.sql("SELECT t.item, t.question, t.required, a.answer FROM field.checklist_template t "
                   "LEFT JOIN field.checklist_answer a ON a.order_id = $1 AND a.item = t.item "
                   "WHERE t.service_product_id = $2 ORDER BY t.item", o["id"], o["service_product_id"])
    ana.table([{"item": r["item"], "pergunta": r["question"], "obrigatória": "sim" if r["required"] else "", "resposta": r["answer"]}
               for r in rows], title=f"Checklist da OS {o['number']}")
    return {"items": len(rows), "missing": [r["item"] for r in rows if r["required"] and not r["answer"]]}
