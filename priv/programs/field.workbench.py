# ana:description Bancada de serviços em campo: chamados a agendar, agenda do dia e OS a faturar
# ana:command campo
"""H4–H8: open calls by deadline, today's visits and finished orders waiting for invoicing."""

PARAMS = {}
PRIO = {"urgent": "urgente", "high": "alta", "normal": "normal", "low": "baixa"}


def main():
    c = ana.sql_one(
        "SELECT count(*) FILTER (WHERE status = 'open') AS to_schedule, "
        "  count(*) FILTER (WHERE status NOT IN ('done', 'invoiced', 'cancelled') AND now() > due_at) AS late, "
        "  count(*) FILTER (WHERE status IN ('scheduled', 'en_route', 'in_progress')) AS active, "
        "  count(*) FILTER (WHERE status = 'done') AS to_invoice FROM field.service_order WHERE status NOT IN ('invoiced', 'cancelled')")
    ana.metrics([{"label": "A agendar", "value": c["to_schedule"], "status": "warn" if c["to_schedule"] else "ok"},
                 {"label": "Fora do prazo", "value": c["late"], "status": "bad" if c["late"] else "ok"},
                 {"label": "Em atendimento", "value": c["active"]},
                 {"label": "A faturar", "value": c["to_invoice"], "status": "warn" if c["to_invoice"] else "ok"}])
    rows = ana.sql("SELECT o.number, p.name, o.priority, o.description, o.due_at, now() > o.due_at AS late FROM field.service_order o "
                   "JOIN base.party p ON p.id = o.customer_id WHERE o.status = 'open' ORDER BY o.due_at LIMIT 200")
    ana.table([{"OS": r["number"], "cliente": r["name"], "prioridade": PRIO[r["priority"]], "pedido": r["description"],
                "prazo": f"{r['due_at']:%d/%m %H:%M}" + (" (atrasada)" if r["late"] else ""),
                "_actions": [{"label": "Agendar", "program": "field.schedule", "params": {"order": r["number"]}, "style": "primary",
                              "ask": {"technician": {"type": "int", "label": "técnico", "required": True,
                                                     "lookup": {"program": "logistics.lookup", "params": {"kind": "technicians"}}},
                                      "start": {"type": "datetime", "label": "início", "required": True},
                                      "hours": {"type": "decimal", "label": "duração (h)"}}}]} for r in rows],
              title="Chamados a agendar")
    done = ana.sql("SELECT o.number, p.name, o.done_at FROM field.service_order o JOIN base.party p ON p.id = o.customer_id "
                   "WHERE o.status = 'done' ORDER BY o.done_at LIMIT 200")
    ana.table([{"OS": r["number"], "cliente": r["name"], "concluída": f"{r['done_at']:%d/%m %H:%M}",
                "_actions": [{"label": "Faturar", "program": "field.invoice_orders", "params": {"orders": [r["number"]]},
                              "style": "primary"}]} for r in done], title="Concluídas, a faturar")
    ana.actions([{"label": "Nova OS", "program": "field.open_order", "open": True},
                 {"label": "Agenda da semana", "program": "field.agenda", "open": True},
                 {"label": "Indicadores de SLA", "program": "field.sla_report", "open": True}], title="Outras tarefas")
    return {"counts": c}
