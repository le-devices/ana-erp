# ana:description Minhas tarefas: pegar, devolver, concluir, aprovar, recusar, delegar ou comentar uma tarefa
# ana:exposed yes
# ana:category Processos/Minhas tarefas
"""Spec 039 (RF-039-12). The task only changes state here; the engine moves the case on (single place).
vars: values the task writes into the case (they feed the decisions ahead)."""

import re

from ana_lib.bpm import common

PARAMS = {
    "task": {"type": "int", "required": True, "label": "tarefa"},
    "action": {"type": "str", "required": True, "label": "ação",
               "choices": [["claim", "Pegar"], ["release", "Devolver ao grupo"], ["complete", "Concluir"], ["approve", "Aprovar"],
                           ["reject", "Recusar"], ["delegate", "Delegar"], ["comment", "Comentar"]]},
    "comment": {"type": "str", "label": "comentário"},
    "to": {"type": "str", "label": "delegar para (usuário)"},
    "vars": {"type": "dict", "label": "dados que a tarefa grava no caso"},
    "result": {"type": "dict", "label": "resultado (ex.: do programa executado)"},
}
VAR = re.compile(r"^[a-z][a-z0-9_]{0,40}$")


def main(task, action, comment=None, to=None, vars=None, result=None):
    t = ana.sql_one("SELECT t.*, c.process_code FROM bpm.task t JOIN bpm.case c ON c.id = t.case_id WHERE t.id = $1 FOR UPDATE OF t",
                    task)
    if not t:
        raise ana.Error("NOT_FOUND", f"tarefa {task} não encontrada")
    me, admin = ana.context.user, ana.context.role == "admin"
    mine = t["assignee"] == me
    candidate = t["assignee"] is None and ((t["role"] and t["role"] == ana.context.role) or (t["group_name"] in common.groups()))
    if not (mine or candidate or admin):
        raise ana.Error("FORBIDDEN", "esta tarefa não é sua nem do seu papel ou grupo")
    if t["status"] != "waiting":
        raise ana.Error("INVALID_STATE", "a tarefa não está aguardando (já foi concluída ou cancelada)")
    if action == "comment":
        if not (comment or "").strip():
            raise ana.Error("INVALID_PARAMETER", "escreva o comentário")
        event(t, "comment", {"text": comment.strip()})
        return {"task": task, "status": t["status"]}
    if action == "claim":
        ana.sql_exec("UPDATE bpm.task SET assignee = $2 WHERE id = $1", task, me)
        event(t, "claim", None)
        return {"task": task, "assignee": me}
    if action == "release":
        if not mine:
            raise ana.Error("INVALID_STATE", "só quem pegou devolve a tarefa")
        if not (t["role"] or t["group_name"]):
            raise ana.Error("INVALID_STATE", "tarefa de uma pessoa: use delegar")
        ana.sql_exec("UPDATE bpm.task SET assignee = NULL WHERE id = $1", task)
        event(t, "release", None)
        return {"task": task, "assignee": None}
    if action == "delegate":
        if not to or not ana.sql_value("SELECT bpm.user_exists($1)", to):
            raise ana.Error("INVALID_PARAMETER", f"usuário {to} não encontrado")
        ana.sql_exec("UPDATE bpm.task SET assignee = $2 WHERE id = $1", task, to)
        ana.sql_exec("INSERT INTO bpm.notification (username, task_id, case_id, kind, message) VALUES ($1, $2, $3, 'task', $4)",
                     to, task, t["case_id"], f"{me} delegou a tarefa: {t['name']}")
        event(t, "delegate", {"to": to, "comment": comment})
        return {"task": task, "assignee": to}
    if action in ("approve", "reject"):
        if t["kind"] != "approval":
            raise ana.Error("INVALID_PARAMETER", "aprovar e recusar são para tarefas de aprovação")
        if action == "reject" and len((comment or "").strip()) < 3:
            raise ana.Error("INVALID_PARAMETER", "diga o motivo da recusa")
        outcome = "approved" if action == "approve" else "rejected"
    elif action == "complete":
        if t["kind"] == "approval":
            raise ana.Error("INVALID_PARAMETER", "use aprovar ou recusar")
        outcome = None
    else:
        raise ana.Error("INVALID_PARAMETER", "ação desconhecida")
    clean = {}
    for k, v in (vars or {}).items():
        if not VAR.match(str(k)) or k.endswith("_decision"):
            raise ana.Error("INVALID_PARAMETER", f"nome de dado inválido: {k}")
        clean[k] = v
    payload = dict(result or {})
    if clean:
        payload["vars"] = clean
    ana.sql_exec("UPDATE bpm.task SET status = 'done', how = 'manual', done_by = $2, outcome = $3, result = $4, comment = $5, "
                 "assignee = COALESCE(assignee, $2), finished_at = now() WHERE id = $1",
                 task, me, outcome, payload or None, (comment or "").strip() or None)
    event(t, "done", {"outcome": outcome, "comment": comment})
    return {"task": task, "status": "done", "outcome": outcome, "case": t["case_id"]}


def event(t, kind, detail):
    ana.sql_exec("INSERT INTO bpm.event (case_id, node, kind, by, detail) VALUES ($1, $2, $3, $4, $5)",
                 t["case_id"], t["node"], kind, ana.context.user, detail)
