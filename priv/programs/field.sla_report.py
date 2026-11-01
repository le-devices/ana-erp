# ana:description Indicadores de serviços em campo: SLA, tempo de resposta, tempo em campo, visitas e retornos
# ana:exposed yes
# ana:command sla
# ana:category Logística e campo/Serviços em campo
"""RF-015-10, CA-015-05. An order is late when it is not done and now > due_at, or when it was
done after due_at. Response = first trip/work − opening. Return = another order of the same
customer and equipment within 30 days."""

import datetime
from ana_lib.docs.common import link as doc_link

PARAMS = {
    "start": {"type": "date", "label": "de (vazio = 30 dias)"},
    "end": {"type": "date", "label": "até (vazio = hoje)"},
}


def main(start=None, end=None):
    end = end or datetime.date.today()
    start = start or end - datetime.timedelta(days=30)
    # Spec 042 (E-04): the numbers come from every order of the period; the table lists the first 2000.
    base = (
        "WITH r AS (SELECT o.number, p.name, o.priority, o.status, o.opened_at, o.due_at, o.first_visit_at, o.done_at, "
        "  (o.status NOT IN ('done', 'invoiced', 'cancelled') AND now() > o.due_at) AS late_open, "
        "  (o.done_at IS NOT NULL AND o.done_at > o.due_at) AS late_done, "
        "  extract(epoch FROM o.first_visit_at - o.opened_at) / 3600 AS response_h, "
        "  (SELECT COALESCE(sum(w.hours), 0) FROM field.work_log w WHERE w.order_id = o.id AND w.kind = 'work') AS field_h, "
        "  EXISTS (SELECT 1 FROM field.service_order x WHERE x.customer_id = o.customer_id AND x.id <> o.id "
        "          AND x.equipment = o.equipment "
        "          AND x.opened_at > o.opened_at AND x.opened_at <= o.opened_at + interval '30 days') AS returned "
        "FROM field.service_order o JOIN base.party p ON p.id = o.customer_id "
        "WHERE o.opened_at >= $1::date AND o.opened_at < $2::date + 1 AND o.status <> 'cancelled') ")
    rows = ana.sql(base + "SELECT * FROM r ORDER BY due_at LIMIT 2000", start, end)
    t = ana.sql_one(base + "SELECT count(*) AS n, count(*) FILTER (WHERE done_at IS NOT NULL) AS done, "
                    "count(*) FILTER (WHERE done_at IS NOT NULL AND NOT late_done) AS met, count(*) FILTER (WHERE late_open) AS late_open, "
                    "avg(response_h) AS response_h, COALESCE(sum(field_h), 0) AS field_h, count(*) FILTER (WHERE returned) AS returned, "
                    "COALESCE(array_agg(number ORDER BY number) FILTER (WHERE late_open OR late_done), '{}') AS late, "
                    "COALESCE(array_agg(number ORDER BY number) FILTER (WHERE late_open), '{}') AS late_open_list FROM r", start, end)
    per_tech = ana.sql("SELECT e.name, count(DISTINCT a.order_id) AS visits FROM field.assignment a JOIN projects.employee e "
                       "ON e.id = a.employee_id WHERE a.status <> 'cancelled' AND a.period && tstzrange($1::date::timestamptz, ($2::date + 1)::timestamptz) "
                       "GROUP BY e.name ORDER BY 2 DESC LIMIT 50", start, end)
    ana.metrics([{"label": "SLA cumprido", "value": f"{100 * t['met'] / t['done']:.0f}%" if t["done"] else "—",
                  "status": "ok" if t["done"] and t["met"] == t["done"] else "warn"},
                 {"label": "Atrasadas agora", "value": t["late_open"], "status": "bad" if t["late_open"] else "ok"},
                 {"label": "Tempo médio de resposta", "value": f"{float(t['response_h']):.1f} h" if t["response_h"] is not None else "—"},
                 {"label": "Horas em campo", "value": f"{float(t['field_h']):.1f} h"},
                 {"label": "Retornos em 30 dias", "value": t["returned"]}])
    labels = {"open": "aberta", "scheduled": "agendada", "en_route": "a caminho", "in_progress": "em atendimento", "done": "concluída",
              "invoiced": "faturada"}
    ana.table([{"OS": r["number"], "_open": doc_link("service_order", r["number"]), "cliente": r["name"], "prioridade": r["priority"], "situação": labels.get(r["status"], r["status"]),
                "aberta": f"{r['opened_at']:%d/%m %H:%M}", "prazo": f"{r['due_at']:%d/%m %H:%M}",
                "resposta (h)": round(float(r["response_h"]), 1) if r["response_h"] is not None else None,
                "atrasada": "sim" if r["late_open"] or r["late_done"] else ""} for r in rows],
              title="Ordens de serviço" + (f" (as 2000 primeiras de {t['n']})" if t["n"] > len(rows) else ""))
    if per_tech:
        ana.chart(type="bar", title="Visitas por técnico", x=[t["name"] for t in per_tech],
                  series=[{"name": "Visitas", "values": [t["visits"] for t in per_tech]}])
    return {"orders": t["n"], "late": list(t["late"]), "late_open": list(t["late_open_list"]),
            "sla_met_pct": round(100 * t["met"] / t["done"], 1) if t["done"] else None}
