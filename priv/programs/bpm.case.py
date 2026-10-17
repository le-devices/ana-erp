# ana:description Processos: painel de um caso — caminho percorrido no diagrama, linha do tempo, dados, tarefas e ações
# ana:exposed yes
"""Spec 039 (RF-039-14). For esteiras use the Esteiras board (flows.board)."""

PARAMS = {"case": {"type": "int", "required": True, "label": "caso"}}


def main(case):
    c = ana.sql_one("SELECT c.*, p.name AS process, p.owner, d.label AS doc_label, d.program AS doc_program FROM bpm.case c "
                    "JOIN bpm.process p ON p.code = c.process_code JOIN bpm.document d ON d.entity = c.doc_entity WHERE c.id = $1", case)
    if not c:
        raise ana.Error("NOT_FOUND", f"caso {case} não encontrado")
    model = ana.sql_value("SELECT model FROM bpm.version WHERE process_code = $1 AND version = $2", c["process_code"], c["version"])
    tasks = ana.sql("SELECT id, node, kind, name, status, assignee, role, group_name, program, priority, due_at, escalated, how, "
                    "  done_by, outcome, comment, error, created_at, finished_at, child_case, "
                    "  extract(epoch FROM COALESCE(finished_at, now()) - created_at) / 3600 AS hours "
                    "FROM bpm.task WHERE case_id = $1 ORDER BY id", case)
    events = ana.sql("SELECT at, node, kind, by, detail FROM bpm.event WHERE case_id = $1 ORDER BY id LIMIT 2000", case)
    tokens = ana.sql("SELECT node, status FROM bpm.token WHERE case_id = $1 AND status IN ('active', 'joining')", case)
    newest = ana.sql_value("SELECT version FROM bpm.version WHERE process_code = $1 AND status = 'published'", c["process_code"])
    manager = ana.context.role in ("admin", "developer") or c["owner"] == ana.context.user
    names = {n["id"]: n.get("name", n["id"]) for n in model["nodes"]}
    return {
        "case": c, "model": model, "tasks": tasks, "events": events,
        "current": sorted({t["node"] for t in tokens}),
        "done": sorted({t["node"] for t in tasks if t["status"] == "done"}),
        "failed": sorted({t["node"] for t in tasks if t["status"] == "failed"}),
        "names": names, "newest_version": newest,
        "can_manage": manager and c["status"] in ("running", "waiting", "failed"),
    }
