# ana:description Monta a estrutura do projeto a partir de um modelo
# ana:exposed yes
# ana:category Projetos/Planejamento
"""RF-021-02, CA-021-01. Copies phases, activities, hours, durations and
dependencies; codes that already exist in the project are kept as they are."""

from ana_lib.projects import access

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto", "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "template": {"type": "str", "required": True, "label": "modelo", "lookup": {"program": "projects.lookup", "params": {"kind": "templates"}}},
}


def main(project, template):
    p = access.project(project, lock=True)
    access.require_manager(p)
    tpl = ana.sql_one("SELECT code FROM projects.template WHERE code = $1 AND active", template.strip().upper())
    if not tpl:
        raise ana.Error("TEMPLATE_NOT_FOUND", f"modelo {template} não encontrado")
    items = ana.sql("SELECT code, predecessors FROM projects.template_item WHERE template_code = $1 ORDER BY seq", tpl["code"])
    base_seq = ana.sql_value("SELECT COALESCE(max(seq), 0) FROM projects.task WHERE project_id = $1", p["id"])
    created = 0
    for kind in ("phase", "activity"):          # phases first: activities point to them
        # One statement per kind; the parent is found by code among the project's tasks.
        # ana:lint-ok sql_in_loop — two fixed passes (phases, then activities), not one per item
        created += len(ana.sql(
            "INSERT INTO projects.task (project_id, code, name, kind, parent_id, seq, profile, planned_hours, "
            "  duration_days, deliverable, billable) "
            "SELECT $1, i.code, i.name, i.kind, parent.id, $3 + i.seq + 1, i.profile, i.planned_hours, i.duration_days, "
            "  i.deliverable, i.billable FROM projects.template_item i "
            "LEFT JOIN projects.task parent ON parent.project_id = $1 AND parent.code = i.parent_code "
            "WHERE i.template_code = $2 AND i.kind = $4 ORDER BY i.seq "
            "ON CONFLICT (project_id, code) DO NOTHING RETURNING id",
            p["id"], tpl["code"], base_seq, kind))
    ids = {r["code"]: r["id"] for r in ana.sql("SELECT code, id FROM projects.task WHERE project_id = $1 AND code = ANY($2)",
                                               p["id"], [i["code"] for i in items])}
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
