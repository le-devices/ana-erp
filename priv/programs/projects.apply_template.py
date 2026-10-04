# ana:description Monta a estrutura do projeto a partir de um modelo
# ana:exposed yes
"""RF-021-02, CA-021-01. Copies phases, activities, hours, durations and
dependencies; codes that already exist in the project are kept as they are."""

from ana_lib.projects import access

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto"},
    "template": {"type": "str", "required": True, "label": "modelo"},
}


def main(project, template):
    p = access.project(project, lock=True)
    access.require_manager(p)
    tpl = ana.sql_one("SELECT * FROM projects.template WHERE code = $1 AND active", template.strip().upper())
    if not tpl:
        raise ana.Error("TEMPLATE_NOT_FOUND", f"modelo {template} não encontrado")
    items = ana.sql("SELECT * FROM projects.template_item WHERE template_code = $1 ORDER BY seq", tpl["code"])
    base_seq = ana.sql_value("SELECT COALESCE(max(seq), 0) FROM projects.task WHERE project_id = $1", p["id"])
    ids, created = {}, 0
    for kind in ("phase", "activity"):          # phases first: activities point to them
        for i in (x for x in items if x["kind"] == kind):
            row = ana.sql_one(
                "INSERT INTO projects.task (project_id, code, name, kind, parent_id, seq, profile, planned_hours, "
                "  duration_days, deliverable, billable) "
                "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) "
                "ON CONFLICT (project_id, code) DO NOTHING RETURNING id",
                p["id"], i["code"], i["name"], i["kind"], ids.get(i["parent_code"]), base_seq + i["seq"] + 1,
                i["profile"], i["planned_hours"], i["duration_days"], i["deliverable"], i["billable"])
            if row:
                created += 1
                ids[i["code"]] = row["id"]
            else:
                ids[i["code"]] = ana.sql_value("SELECT id FROM projects.task WHERE project_id = $1 AND code = $2",
                                               p["id"], i["code"])
    deps = [[ids[i["code"]], ids[pre]] for i in items for pre in i["predecessors"] if pre in ids]
    if deps:
        ana.sql_batch("INSERT INTO projects.task_dependency (task_id, predecessor_id) VALUES ($1, $2) "
                      "ON CONFLICT DO NOTHING", deps)
    ana.log(f"{created} item(ns) criado(s) a partir do modelo {tpl['code']}")
    ana.actions([{"label": "Ver estrutura", "program": "projects.workspace", "open": True,
                  "params": {"project": p["code"], "view": "structure"}},
                 {"label": "Alocar pessoas", "program": "projects.workspace", "open": True,
                  "params": {"project": p["code"], "view": "allocation"}}], title="Próximo passo")
    return {"project": p["code"], "created": created}
