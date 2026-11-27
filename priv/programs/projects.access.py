# ana:description Regras de acesso e consultas comuns do módulo de projetos
# ana:kind library
"""Who may manage a project (manager or admin) and shared lookups.

RNF-008-02: cost and margin only for whoever manages the project.
"""

import ana
from ana_lib.util.format import status_text


def is_admin():
    return ana.context.role == "admin"


def require_admin():
    if not is_admin():
        raise ana.Error("FORBIDDEN", "operação restrita ao administrador")


def project(code, lock=False):
    p = ana.sql_one("SELECT id, code, name, customer_id, manager, billing, status, start_date, due_date, budget_hours, "
                    "budget_amount, service_tax_rate, service_tax_withheld, description, created_at, "
                    "cost_center FROM projects.project WHERE code = $1" + (" FOR UPDATE" if lock else ""),
                    str(code).upper())
    if not p:
        raise ana.Error("PROJECT_NOT_FOUND", f"projeto {code} não encontrado")
    return p


def can_manage(p):
    return is_admin() or p["manager"] == ana.context.user


def require_manager(p):
    if not can_manage(p):
        raise ana.Error("FORBIDDEN", f"apenas o gestor do projeto {p['code']} ou um administrador")


def can_invoice(p):
    """Spec 008 (H6): the finance team invoices the project — besides its manager and the administrators. The finance
    team: an access group whose routines include the bank statement (migration 088); nobody else by default."""
    return can_manage(p) or bool(ana.sql_value("SELECT projects.is_finance($1)", ana.context.user))


def require_invoicer(p):
    if not can_invoice(p):
        raise ana.Error("FORBIDDEN", f"apenas o financeiro, o gestor do projeto {p['code']} ou um administrador")


def current_employee():
    return ana.sql_one("SELECT id, name, profile FROM projects.employee WHERE username = $1 AND active",
                       ana.context.user)


def require_active(p):
    if p["status"] != "active":
        raise ana.Error("PROJECT_INACTIVE", f"projeto {p['code']} está {status_text(p['status'])}")
