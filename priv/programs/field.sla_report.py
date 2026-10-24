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
    rows = ana.sql(
        "SELECT o.number, p.name, o.priority, o.status, o.opened_at, o.due_at, o.first_visit_at, o.done_at, "
        "  (o.status NOT IN ('done', 'invoiced', 'cancelled') AND now() > o.due_at) AS late_open, "
        "  (o.done_at IS NOT NULL AND o.done_at > o.due_at) AS late_done, "
        "  extract(epoch FROM o.first_visit_at - o.opened_at) / 3600 AS response_h, "
        "  (SELECT COALESCE(sum(w.hours), 0) FROM field.work_log w WHERE w.order_id = o.id AND w.kind = 'work') AS field_h, "
        "  EXISTS (SELECT 1 FROM field.service_order r WHERE r.customer_id = o.customer_id AND r.id <> o.id "
        "          AND r.equipment = o.equipment "
        "          AND r.opened_at > o.opened_at AND r.opened_at <= o.opened_at + interval '30 days') AS returned "
        "FROM field.service_order o JOIN base.party p ON p.id = o.customer_id "
        "WHERE o.opened_at >= $1::date AND o.opened_at < $2::date + 1 AND o.status <> 'cancelled' ORDER BY o.due_at LIMIT 2000",
        start, end)
    done = [r for r in rows if r["done_at"]]
    met = [r for r in done if not r["late_done"]]
    late = [r for r in rows if r["late_open"] or r["late_done"]]
    resp = [float(r["response_h"]) for r in rows if r["response_h"] is not None]
    per_tech = ana.sql("SELECT e.name, count(DISTINCT a.order_id) AS visits FROM field.assignment a JOIN projects.employee e "
                       "ON e.id = a.employee_id WHERE a.status <> 'cancelled' AND a.period && tstzrange($1::date::timestamptz, ($2::date + 1)::timestamptz) "
                       "GROUP BY e.name ORDER BY 2 DESC LIMIT 50", start, end)
    ana.metrics([{"label": "SLA cumprido", "value": f"{100 * len(met) / len(done):.0f}%" if done else "—",
                  "status": "ok" if done and len(met) == len(done) else "warn"},
                 {"label": "Atrasadas agora", "value": sum(1 for r in rows if r["late_open"]),
                  "status": "bad" if any(r["late_open"] for r in rows) else "ok"},
                 {"label": "Tempo médio de resposta", "value": f"{sum(resp) / len(resp):.1f} h" if resp else "—"},
                 {"label": "Horas em campo", "value": f"{sum(float(r['field_h']) for r in rows):.1f} h"},
                 {"label": "Retornos em 30 dias", "value": sum(1 for r in rows if r["returned"])}])
    labels = {"open": "aberta", "scheduled": "agendada", "en_route": "a caminho", "in_progress": "em atendimento", "done": "concluída",
              "invoiced": "faturada"}
    ana.table([{"OS": r["number"], "_open": doc_link("service_order", r["number"]), "cliente": r["name"], "prioridade": r["priority"], "situação": labels.get(r["status"], r["status"]),
                "aberta": f"{r['opened_at']:%d/%m %H:%M}", "prazo": f"{r['due_at']:%d/%m %H:%M}",
                "resposta (h)": round(float(r["response_h"]), 1) if r["response_h"] is not None else None,
                "atrasada": "sim" if r["late_open"] or r["late_done"] else ""} for r in rows], title="Ordens de serviço")
    if per_tech:
        ana.chart(type="bar", title="Visitas por técnico", x=[t["name"] for t in per_tech],
                  series=[{"name": "Visitas", "values": [t["visits"] for t in per_tech]}])
    return {"late": [r["number"] for r in late], "late_open": [r["number"] for r in rows if r["late_open"]],
            "sla_met_pct": round(100 * len(met) / len(done), 1) if done else None}
