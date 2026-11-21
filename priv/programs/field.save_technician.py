# ana:description Técnico de campo: colaborador e depósito do veículo/maleta (peças)
# ana:exposed yes
# ana:category Logística e campo/Serviços em campo
"""RF-015-06/08. The technician is an employee (spec 008): profile and rate, absences."""

from ana_lib.logistics import common

PARAMS = {
    "employee": {"type": "int", "required": True, "label": "colaborador", "lookup": {"program": "projects.lookup", "params": {"kind": "employees"}}},
    "warehouse": {"type": "str", "label": "depósito do veículo/maleta", "lookup": {"program": "logistics.lookup", "params": {"kind": "warehouses"}}},
    "active": {"type": "bool", "default": True, "label": "ativo"},
}


def main(employee, warehouse=None, active=True):
    if not ana.sql_value("SELECT count(*) FROM projects.employee WHERE id = $1 AND active", employee):
        raise ana.Error("EMPLOYEE_NOT_FOUND", f"colaborador {employee} não encontrado")
    w = common.warehouse(warehouse)["id"] if warehouse else None
    ana.sql_exec("INSERT INTO field.technician (employee_id, warehouse_id, active) VALUES ($1, $2, $3) "
                 "ON CONFLICT (employee_id) DO UPDATE SET warehouse_id = EXCLUDED.warehouse_id, active = EXCLUDED.active",
                 employee, w, active)
    return {"employee": employee}
