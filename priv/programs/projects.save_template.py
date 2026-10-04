# ana:description Cria ou atualiza modelo de projeto (fases, atividades, horas típicas)
# ana:exposed yes
"""RF-021-02. Templates are data of each client (P13); admin only.

Example items:
  [{"code": "1", "kind": "phase", "name": "Especificação"},
   {"code": "1.1", "parent": "1", "name": "Requisitos", "profile": "PM", "planned_hours": 24,
    "duration_days": 5, "deliverable": "Documento de requisitos"},
   {"code": "2.1", "parent": "2", "name": "Esquemático", "predecessors": ["1.1"]}]
"""

from ana_lib.projects import access

PARAMS = {
    "code": {"type": "str", "required": True},
    "name": {"type": "str", "required": True},
    "service_kind": {"type": "str", "default": ""},
    "description": {"type": "str", "default": ""},
    "items": {"type": "list", "required": True},
}


def main(code, name, items, service_kind="", description=""):
    access.require_admin()
    code = code.strip().upper()
    codes = {str(i["code"]) for i in items}
    for i in items:
        if i.get("kind", "activity") == "phase" and i.get("parent"):
            raise ana.Error("INVALID_PARAMETER", f"fase {i['code']} não pode ter fase-mãe")
        if i.get("parent") and str(i["parent"]) not in codes:
            raise ana.Error("INVALID_PARAMETER", f"item {i['code']}: fase {i['parent']} não existe no modelo")
        for pre in i.get("predecessors", []):
            if str(pre) not in codes:
                raise ana.Error("INVALID_PARAMETER", f"item {i['code']}: predecessora {pre} não existe no modelo")
    ana.sql_exec(
        "INSERT INTO projects.template (code, name, service_kind, description) VALUES ($1, $2, $3, $4) "
        "ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, service_kind = EXCLUDED.service_kind, "
        "description = EXCLUDED.description, active = true", code, name, service_kind, description)
    ana.sql_exec("DELETE FROM projects.template_item WHERE template_code = $1", code)
    ana.sql_batch(
        "INSERT INTO projects.template_item (template_code, code, seq, kind, parent_code, name, profile, "
        "  planned_hours, duration_days, predecessors, deliverable, billable) "
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)",
        [[code, str(i["code"]), n, i.get("kind", "activity"), i.get("parent") and str(i["parent"]), i["name"],
          i.get("profile") and str(i["profile"]).upper(), i.get("planned_hours"), i.get("duration_days"),
          [str(x) for x in i.get("predecessors", [])], i.get("deliverable"), i.get("billable", True)]
         for n, i in enumerate(items)])
    return {"code": code, "items": len(items)}
