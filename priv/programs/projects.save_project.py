# ana:description Cria ou atualiza projeto com tarefas, equipe e valores-hora
# ana:exposed yes
# ana:command project
"""Upsert by code. Creating requires admin; changing requires manager or admin.

Example:
  {"code": "PRJ-002", "name": "Firmware BLE", "customer": 1, "manager": "admin",
   "billing": "hourly", "status": "active",
   "tasks": [{"code": "1", "name": "Firmware", "planned_hours": 120}],
   "team": [{"employee": 1, "profile": "FW"}],
   "rates": {"FW": 210}}
"""

from decimal import Decimal

from ana_lib.projects import access

PARAMS = {
    "code": {"type": "str", "required": True, "label": "código"},
    "name": {"type": "str", "label": "nome"},
    "customer": {"type": "int", "label": "cliente", "lookup": {"program": "sales.lookup", "params": {"kind": "customers"}}},
    "manager": {"type": "str", "label": "gestor (usuário)"},
    "billing": {"type": "str", "label": "faturamento", "choices": [["hourly", "Por hora"], ["fixed", "Preço fechado"], ["mixed", "Misto"]]},
    "status": {"type": "str", "label": "situação", "choices": [["proposal", "Proposta"], ["active", "Ativo"], ["suspended", "Suspenso"], ["closed", "Encerrado"]]},
    "start_date": {"type": "date", "label": "início"},
    "due_date": {"type": "date", "label": "vencimento/prazo"},
    "budget_hours": {"type": "decimal", "label": "orçamento (horas)"},
    "budget_amount": {"type": "decimal", "label": "orçamento (valor)"},
    "service_tax_rate": {"type": "decimal", "label": "alíquota do imposto sobre serviço"},
    "service_tax_withheld": {"type": "bool", "label": "imposto retido pelo cliente"},
    "description": {"type": "str", "label": "descrição"},
    "cost_center": {"type": "str", "label": "centro de custo", "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}},
    "tasks": {"type": "list", "default": [], "label": "atividades"},
    "team": {"type": "list", "default": [], "label": "equipe"},
    "rates": {"type": "dict", "default": {}, "label": "valores por perfil"},
}

COLUMNS = ["name", "customer_id", "manager", "billing", "status", "start_date", "due_date",
           "budget_hours", "budget_amount", "service_tax_rate", "service_tax_withheld", "description", "cost_center"]


def main(code, tasks=(), team=(), rates=None, customer=None, **fields):
    code = code.strip().upper()
    fields["customer_id"] = customer
    if fields.get("cost_center"):
        fields["cost_center"] = fields["cost_center"].strip().upper()
    current = ana.sql_one("SELECT id, code, manager FROM projects.project WHERE code = $1 FOR UPDATE", code)
    if current is None:
        access.require_admin()
        missing = [c for c in ("name", "customer_id", "manager") if fields.get(c) is None]
        if missing:
            raise ana.Error("INVALID_PARAMETER", "projeto novo exige: " + ", ".join(missing))
        project_id = ana.sql_value(
            "INSERT INTO projects.project (code, name, customer_id, manager, billing, status, start_date, "
            "  due_date, budget_hours, budget_amount, service_tax_rate, service_tax_withheld, description, cost_center) "
            "VALUES ($1, $2, $3, $4, COALESCE($5, 'hourly'), COALESCE($6, 'proposal'), $7, $8, $9, $10, "
            "        COALESCE($11::numeric, 0), COALESCE($12::boolean, false), $13, $14) RETURNING id",
            code, *[fields.get(c) for c in COLUMNS])
        created = True
    else:
        access.require_manager(current)
        project_id = current["id"]
        ana.sql_exec("UPDATE projects.project SET name = COALESCE($2, name), customer_id = COALESCE($3, customer_id), "
                     "manager = COALESCE($4, manager), billing = COALESCE($5, billing), status = COALESCE($6, status), "
                     "start_date = COALESCE($7, start_date), due_date = COALESCE($8, due_date), "
                     "budget_hours = COALESCE($9, budget_hours), budget_amount = COALESCE($10, budget_amount), "
                     "service_tax_rate = COALESCE($11, service_tax_rate), "
                     "service_tax_withheld = COALESCE($12, service_tax_withheld), "
                     "description = COALESCE($13, description), cost_center = COALESCE($14, cost_center) WHERE id = $1",
                     project_id, *[fields.get(c) for c in COLUMNS])
        created = False

    if tasks:
        ana.sql_batch(
            "INSERT INTO projects.task (project_id, code, name, planned_hours, billable, active) "
            "VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (project_id, code) DO UPDATE SET "
            "name = EXCLUDED.name, planned_hours = EXCLUDED.planned_hours, "
            "billable = EXCLUDED.billable, active = EXCLUDED.active",
            [[project_id, str(t["code"]), t["name"], t.get("planned_hours"), t.get("billable", True),
              t.get("active", True)] for t in tasks])
    team = [{**m, "employee": int(m["employee"])} for m in team]
    removed = [m["employee"] for m in team if m.get("remove")]
    if removed:
        ana.sql_exec("DELETE FROM projects.project_member WHERE project_id = $1 AND employee_id = ANY($2)",
                     project_id, removed)
    members = [m for m in team if not m.get("remove")]
    if members:
        profiles = {r["id"]: r["profile"] for r in ana.sql("SELECT id, profile FROM projects.employee WHERE id = ANY($1)",
                                                         [m["employee"] for m in members])}
        missing = [str(m["employee"]) for m in members if m["employee"] not in profiles]
        if missing:
            raise ana.Error("EMPLOYEE_NOT_FOUND", "colaborador(es) inexistente(s): " + ", ".join(missing))
        ana.sql_batch(
            "INSERT INTO projects.project_member (project_id, employee_id, profile) VALUES ($1, $2, $3) "
            "ON CONFLICT (project_id, employee_id) DO UPDATE SET profile = EXCLUDED.profile",
            [[project_id, m["employee"], str(m.get("profile") or profiles[m["employee"]]).upper()] for m in members])
    if rates:
        ana.sql_batch(
            "INSERT INTO projects.project_rate (project_id, profile, hourly_rate) VALUES ($1, $2, $3) "
            "ON CONFLICT (project_id, profile) DO UPDATE SET hourly_rate = EXCLUDED.hourly_rate",
            [[project_id, profile.upper(), Decimal(str(rate))] for profile, rate in rates.items()])
    return {"id": project_id, "code": code, "created": created}
