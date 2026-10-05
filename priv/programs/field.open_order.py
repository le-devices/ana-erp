# ana:description Abre ordem de serviço (instalação, manutenção, calibração, suporte) com prazo de SLA
# ana:exposed yes
# ana:portal yes
# ana:command os
"""RF-015-05, RF-015-11. Exposed (app, integration) and on the customer portal: a portal account
opens calls only for its own company. due_at = opened_at + SLA hours (customer contract, else the
priority policy). client_key makes a retried call create nothing twice (RNF-015-02)."""

import datetime

PARAMS = {
    "customer": {"type": "int", "label": "cliente (portal: o seu)", "order": 1},
    "description": {"type": "str", "required": True, "label": "o que precisa ser feito", "order": 2},
    "priority": {"type": "str", "default": "normal", "label": "prioridade", "order": 3,
                 "choices": [["low", "Baixa"], ["normal", "Normal"], ["high", "Alta"], ["urgent", "Urgente"]]},
    "service": {"type": "str", "label": "serviço", "order": 4, "lookup": {"program": "logistics.lookup", "params": {"kind": "services"}}},
    "site_address": {"type": "str", "label": "endereço do atendimento", "order": 5},
    "contact": {"type": "str", "label": "contato no local", "order": 6},
    "equipment": {"type": "str", "label": "equipamento", "order": 7},
    "serial_number": {"type": "str", "label": "nº de série", "order": 8},
    "project": {"type": "str", "label": "projeto (horas e peças vão para o projeto)", "order": 9,
                "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "activity": {"type": "str", "label": "atividade do projeto", "order": 10},
    "latitude": {"type": "decimal", "label": "latitude", "order": 11},
    "longitude": {"type": "decimal", "label": "longitude", "order": 12},
    "opened_at": {"type": "str", "label": "aberta em (integração; vazio = agora)", "order": 13},
    "client_key": {"type": "str", "label": "chave do cliente (idempotência)", "order": 14},
}


def main(description, customer=None, priority="normal", service=None, site_address="", contact="", equipment=None,
         serial_number=None, project=None, activity=None, latitude=None, longitude=None, opened_at=None, client_key=None):
    if ana.context.party:
        if customer and int(customer) != int(ana.context.party):
            raise ana.Error("FORBIDDEN", "a conta do portal abre chamados só da própria empresa")
        customer = ana.context.party
        project = activity = None
    if not customer:
        raise ana.Error("INVALID_PARAMETER", "informe o cliente")
    if client_key:
        done = ana.sql_one("SELECT number, due_at FROM field.service_order WHERE client_key = $1", client_key)
        if done:
            return {"number": done["number"], "due_at": done["due_at"], "repeated": True}
    if not ana.sql_value("SELECT count(*) FROM base.party WHERE id = $1 AND active AND kind IN ('customer', 'both')", customer):
        raise ana.Error("CUSTOMER_NOT_FOUND", f"cliente {customer} não encontrado")
    svc = None
    if service:
        svc = ana.sql_value("SELECT id FROM base.product WHERE code = $1 AND kind = 'service' AND active", service.upper())
        if not svc:
            raise ana.Error("SERVICE_NOT_FOUND", f"serviço {service} não encontrado")
    prj = task = None
    if project:
        prj = ana.sql_value("SELECT id FROM projects.project WHERE code = $1 AND status <> 'closed'", project.upper())
        if not prj:
            raise ana.Error("PROJECT_NOT_FOUND", f"projeto {project} não encontrado")
        task = ana.sql_value("SELECT id FROM projects.task WHERE project_id = $1 AND code = $2 AND active", prj, str(activity or ""))
        if not task:
            raise ana.Error("TASK_NOT_FOUND", "OS de projeto exige a atividade onde as horas serão apontadas")
    at = datetime.datetime.fromisoformat(opened_at) if opened_at else None
    hours = ana.sql_value("SELECT COALESCE((SELECT hours FROM field.customer_sla WHERE customer_id = $1 AND priority = $2), "
                          "(SELECT hours FROM field.sla_policy WHERE priority = $2))", customer, priority)
    if hours is None:
        raise ana.Error("INVALID_PRIORITY", f"prioridade inválida: {priority}")
    o = ana.sql_one("INSERT INTO field.service_order (customer_id, site_address, contact, latitude, longitude, service_product_id, "
                    "  equipment, serial_number, priority, description, project_id, task_id, opened_at, due_at, client_key, created_by) "
                    "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, COALESCE($13::timestamptz, now()), "
                    "  COALESCE($13::timestamptz, now()) + make_interval(hours => $14), $15, $16) RETURNING number, due_at",
                    customer, site_address or "", contact or "", latitude, longitude, svc, equipment, serial_number, priority,
                    description, prj, task, at, hours, client_key, ana.context.user)
    return {"number": o["number"], "due_at": o["due_at"], "sla_hours": hours}
