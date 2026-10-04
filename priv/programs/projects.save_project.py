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
    "code": {"type": "str", "required": True},
    "name": {"type": "str"},
    "customer": {"type": "int"},
    "manager": {"type": "str"},
    "billing": {"type": "str"},
    "status": {"type": "str"},
    "start_date": {"type": "date"},
    "due_date": {"type": "date"},
    "budget_hours": {"type": "decimal"},
    "budget_amount": {"type": "decimal"},
    "service_tax_rate": {"type": "decimal"},
    "service_tax_withheld": {"type": "bool"},
    "description": {"type": "str"},
    "cost_center": {"type": "str", "label": "centro de custo", "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}},
    "tasks": {"type": "list", "default": []},
    "team": {"type": "list", "default": []},
    "rates": {"type": "dict", "default": {}},
}

COLUMNS = ["name", "customer_id", "manager", "billing", "status", "start_date", "due_date",
           "budget_hours", "budget_amount", "service_tax_rate", "service_tax_withheld", "description", "cost_center"]


def main(code, tasks=(), team=(), rates=None, customer=None, **fields):
    code = code.strip().upper()
    fields["customer_id"] = customer
    if fields.get("cost_center"):
        fields["cost_center"] = fields["cost_center"].strip().upper()
    current = ana.sql_one("SELECT * FROM projects.project WHERE code = $1 FOR UPDATE", code)
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
        sets = [f"{c} = COALESCE(${i + 2}, {c})" for i, c in enumerate(COLUMNS)]
        ana.sql_exec(f"UPDATE projects.project SET {', '.join(sets)} WHERE id = $1",
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
    for m in team:
        if m.get("remove"):
            ana.sql_exec("DELETE FROM projects.project_member WHERE project_id = $1 AND employee_id = $2",
                         project_id, m["employee"])
            continue
        profile = m.get("profile") or ana.sql_value(
            "SELECT profile FROM projects.employee WHERE id = $1", m["employee"])
        if profile is None:
            raise ana.Error("EMPLOYEE_NOT_FOUND", f"colaborador {m['employee']} não existe")
        ana.sql_exec(
            "INSERT INTO projects.project_member (project_id, employee_id, profile) VALUES ($1, $2, $3) "
            "ON CONFLICT (project_id, employee_id) DO UPDATE SET profile = EXCLUDED.profile",
            project_id, m["employee"], str(profile).upper())
    for profile, rate in (rates or {}).items():
        ana.sql_exec(
            "INSERT INTO projects.project_rate (project_id, profile, hourly_rate) VALUES ($1, $2, $3) "
            "ON CONFLICT (project_id, profile) DO UPDATE SET hourly_rate = EXCLUDED.hourly_rate",
            project_id, profile.upper(), Decimal(str(rate)))
    return {"id": project_id, "code": code, "created": created}
