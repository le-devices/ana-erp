# ana:description Minhas tarefas: o que é meu e do meu papel ou grupo, com prazo, prioridade e o próximo passo
# ana:exposed yes
# ana:command tarefas
# ana:category Processos/Minhas tarefas
"""Spec 039 (RF-039-12, CA-039-02). Only what the user may do; overdue first, then by priority and deadline."""

from ana_lib.bpm import common

PARAMS = {"scope": {"type": "str", "default": "mine", "label": "quais",
                    "choices": [["mine", "Minhas e do meu papel/grupo"], ["assigned", "Só as atribuídas a mim"], ["all", "Todas (administrador)"]]},
          "q": {"type": "str", "label": "buscar"}}


def visible_sql():
    return ("(t.assignee = $1::text OR (t.assignee IS NULL AND ((t.role IS NOT NULL AND t.role = $2::text) OR "
            " (t.group_name IS NOT NULL AND t.group_name = ANY($3::text[])))))")


def main(scope="mine", q=None):
    groups = sorted(common.groups())
    every = "($1::text IS NOT NULL OR $2::text IS NOT NULL OR $3::text[] IS NOT NULL OR true)"
    cond = {"mine": visible_sql(), "assigned": f"t.assignee = $1::text AND {every}",
            "all": every if ana.context.role == "admin" else visible_sql()}[scope]
    rows = ana.sql(
        "SELECT t.id, t.case_id, t.node, t.kind, t.name, t.status, t.assignee, t.role, t.group_name, t.program, t.params, "
        "  t.instructions, t.priority, t.due_at, t.created_at, t.escalated, t.fact, (t.due_at < now()) AS late, "
        "  t.context, t.actions, "
        "  c.title, c.process_code, c.doc_entity, c.doc_key, p.name AS process, d.program AS doc_program "
        "FROM bpm.task t JOIN bpm.case c ON c.id = t.case_id JOIN bpm.process p ON p.code = c.process_code "
        "JOIN bpm.document d ON d.entity = c.doc_entity "
        f"WHERE t.status = 'waiting' AND t.kind IN ('human', 'approval') AND {cond} "
        "  AND ($4::text IS NULL OR base.norm(t.name || ' ' || c.title) LIKE '%' || base.norm($4) || '%') "
        "ORDER BY (t.due_at < now()) DESC, t.priority, t.due_at NULLS LAST, t.id LIMIT 500",
        ana.context.user, ana.context.role, groups, q)
    unread = ana.sql_value("SELECT count(*) FROM bpm.notification WHERE username = $1 AND NOT read", ana.context.user)
    return {"tasks": rows, "late": sum(1 for r in rows if r["late"]), "unread": unread}
