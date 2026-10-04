# ana:description Opções para campos de escolha do módulo de projetos
# ana:kind program
# ana:menu no
"""Lookup for forms: returns [{"value", "label"}] of what the user may see.

kind: projects | activities | phases | employees | templates | profiles.
Used by PARAMS entries with "lookup" (the screen calls it while filling the form).
"""

from ana_lib.projects import access

PARAMS = {
    "kind": {"type": "str", "required": True, "label": "tipo",
             "choices": ["projects", "activities", "phases", "employees", "templates", "profiles"]},
    "project": {"type": "str", "label": "projeto"},
}


def main(kind, project=None):
    if kind == "projects":
        rows = ana.sql(
            "SELECT p.code, p.name, p.status FROM projects.project p "
            "WHERE $1 OR p.manager = $2 OR EXISTS (SELECT 1 FROM projects.project_member pm "
            "  JOIN projects.employee e ON e.id = pm.employee_id WHERE pm.project_id = p.id AND e.username = $2) "
            "ORDER BY p.status = 'closed', p.code", access.is_admin(), ana.context.user)
        return [{"value": r["code"], "label": f"{r['code']} — {r['name']}" + (" (encerrado)" if r["status"] == "closed" else "")}
                for r in rows]
    if kind in ("activities", "phases"):
        if not project:
            return []
        rows = ana.sql(
            "SELECT t.code, t.name FROM projects.task t JOIN projects.project p ON p.id = t.project_id "
            "WHERE p.code = upper($1) AND t.active AND t.kind = $2 ORDER BY t.seq, t.code",
            project, "activity" if kind == "activities" else "phase")
        return [{"value": r["code"], "label": f"{r['code']} {r['name']}"} for r in rows]
    if kind == "employees":
        rows = ana.sql("SELECT id, name, profile FROM projects.employee WHERE active ORDER BY name")
        return [{"value": r["id"], "label": f"{r['name']} ({r['profile']})"} for r in rows]
    if kind == "templates":
        rows = ana.sql("SELECT code, name FROM projects.template WHERE active ORDER BY name")
        return [{"value": r["code"], "label": f"{r['name']} ({r['code']})"} for r in rows]
    if kind == "profiles":
        rows = ana.sql("SELECT code, description FROM projects.rate_profile WHERE active ORDER BY code")
        return [{"value": r["code"], "label": f"{r['code']} — {r['description']}"} for r in rows]
    return []
