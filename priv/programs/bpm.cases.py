# ana:description Processos: casos de um processo (em andamento, concluídos, com falha), com busca
# ana:exposed yes
"""Spec 039 (RF-039-14, 15)."""

PARAMS = {"process": {"type": "str", "label": "processo (vazio = todos)"},
          "status": {"type": "str", "default": "open", "label": "situação",
                     "choices": [["open", "Em andamento"], ["failed", "Com falha"], ["done", "Concluídos"], ["all", "Todos"]]},
          "q": {"type": "str", "label": "buscar"}}


def main(process=None, status="open", q=None):
    cond = {"open": "c.status IN ('running', 'waiting', 'failed')", "failed": "c.status = 'failed'", "done": "c.status = 'done'",
            "all": "true"}[status]
    rows = ana.sql(
        "SELECT c.id, c.process_code, p.name AS process, c.version, c.status, c.title, c.doc_entity, c.doc_key, c.started_by, "
        "  c.started_at, c.finished_at, c.reason, "
        "  (SELECT string_agg(t.name, ', ') FROM bpm.task t WHERE t.case_id = c.id AND t.status IN ('waiting', 'ready', 'running', 'failed')) AS at, "
        "  (SELECT count(*) FROM bpm.task t WHERE t.case_id = c.id AND t.status = 'waiting' AND t.due_at < now()) AS late "
        "FROM bpm.case c JOIN bpm.process p ON p.code = c.process_code "
        f"WHERE ($1::text IS NULL OR c.process_code = $1) AND {cond} "
        "  AND ($2::text IS NULL OR base.norm(c.title) LIKE '%' || base.norm($2) || '%') ORDER BY c.id DESC LIMIT 500", process, q)
    return {"cases": rows}
