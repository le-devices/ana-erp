# ana:description Regras comuns dos serviços em campo: ordem, técnico e idempotência
# ana:kind library
"""Shared by the field service programs (spec 015)."""

import ana


def order(number, lock=False):
    o = ana.sql_one("SELECT o.id, o.number, o.customer_id, o.status, o.priority, o.project_id, o.task_id, o.service_product_id, "
                    "  o.opened_at, o.due_at, o.first_visit_at, p.name AS customer FROM field.service_order o "
                    "JOIN base.party p ON p.id = o.customer_id WHERE o.number = $1" + (" FOR UPDATE OF o" if lock else ""), number)
    if not o:
        raise ana.Error("SERVICE_ORDER_NOT_FOUND", f"OS {number} não encontrada")
    return o


def technician(employee_id):
    t = ana.sql_one("SELECT e.id, e.name, e.profile, e.username, t.warehouse_id, rp.hourly_rate FROM field.technician t "
                    "JOIN projects.employee e ON e.id = t.employee_id JOIN projects.rate_profile rp ON rp.code = e.profile "
                    "WHERE t.employee_id = $1 AND t.active AND e.active", employee_id)
    if not t:
        raise ana.Error("TECHNICIAN_NOT_FOUND", f"técnico {employee_id} não encontrado ou inativo")
    return t


def current_technician():
    t = ana.sql_one("SELECT e.id FROM projects.employee e JOIN field.technician t ON t.employee_id = e.id "
                    "WHERE e.username = $1 AND t.active", ana.context.user)
    return t["id"] if t else None


def require_open(o):
    if o["status"] in ("done", "invoiced", "cancelled"):
        raise ana.Error("ORDER_CLOSED", f"OS {o['number']} está {o['status']}")


def advance(o, status):
    """Moves forward only (open → scheduled → en_route → in_progress)."""
    rank = ["open", "scheduled", "en_route", "in_progress"]
    if o["status"] in rank and rank.index(status) > rank.index(o["status"]):
        ana.sql_exec("UPDATE field.service_order SET status = $2, first_visit_at = CASE WHEN $2 IN ('en_route', 'in_progress') "
                     "THEN COALESCE(first_visit_at, now()) ELSE first_visit_at END WHERE id = $1", o["id"], status)
