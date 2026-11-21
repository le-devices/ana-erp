# ana:description Processos: ações de quem cuida do caso — reprocessar tarefa com falha, pular com justificativa, cancelar, migrar de versão
# ana:exposed yes
# ana:category Processos/Acompanhamento
"""Spec 039 (RF-039-06, RF-039-14). Administrators, developers and the process owner."""

PARAMS = {"case": {"type": "int", "required": True, "label": "caso"},
          "action": {"type": "str", "required": True, "label": "ação",
                     "choices": [["retry", "Reprocessar"], ["skip", "Pular etapa"], ["cancel", "Cancelar o caso"],
                                 ["migrate", "Migrar para a versão publicada"]]},
          "task": {"type": "int", "label": "tarefa"},
          "reason": {"type": "str", "label": "motivo"}}


def main(case, action, task=None, reason=None):
    c = ana.sql_one("SELECT c.*, p.owner FROM bpm.case c JOIN bpm.process p ON p.code = c.process_code WHERE c.id = $1 FOR UPDATE OF c",
                    case)
    if not c:
        raise ana.Error("NOT_FOUND", f"caso {case} não encontrado")
    if not (ana.context.role in ("admin", "developer") or c["owner"] == ana.context.user):
        raise ana.Error("FORBIDDEN", "só o dono do processo, desenvolvedores e administradores agem sobre o caso")
    if action == "cancel":
        ana.sql("SELECT bpm.cancel_case($1, $2, $3)", case, ana.context.user, (reason or "").strip())
        return {"case": case, "status": "cancelled"}
    if action == "migrate":
        v = ana.sql_value("SELECT version FROM bpm.version WHERE process_code = $1 AND status = 'published'", c["process_code"])
        if v == c["version"]:
            return {"case": case, "version": v, "migrated": False}
        ana.sql("SELECT bpm.migrate_case($1, $2, $3)", case, v, ana.context.user)
        return {"case": case, "version": v, "migrated": True}
    t = ana.sql_one("SELECT * FROM bpm.task WHERE id = $1 AND case_id = $2 FOR UPDATE", task, case)
    if not t:
        raise ana.Error("NOT_FOUND", "tarefa não encontrada neste caso")
    if action == "retry":
        if t["status"] != "failed":
            raise ana.Error("INVALID_STATE", "só tarefas com falha são reprocessadas")
        auto = t["kind"] in ("auto", "send", "timer", "subprocess")
        ana.sql_exec("UPDATE bpm.task SET status = $2, advanced = false, attempts = 0, error = NULL, next_at = now(), "
                     "finished_at = NULL WHERE id = $1", task, "ready" if auto else "waiting")
        ana.sql_exec("UPDATE bpm.case SET status = 'running', reason = NULL, updated_at = now() WHERE id = $1", case)
        log(case, t["node"], "retry", None)
        return {"case": case, "task": task, "status": "ready" if auto else "waiting"}
    if action == "skip":
        if t["status"] not in ("waiting", "failed", "ready"):
            raise ana.Error("INVALID_STATE", "a tarefa não está aguardando nem com falha")
        if len((reason or "").strip()) < 3:
            raise ana.Error("INVALID_PARAMETER", "diga o motivo para pular a etapa")
        ana.sql_exec("UPDATE bpm.task SET status = 'done', advanced = false, how = 'skipped', done_by = $2, comment = $3, "
                     "finished_at = now() WHERE id = $1", task, ana.context.user, reason.strip())
        ana.sql_exec("UPDATE bpm.case SET status = 'running', reason = NULL, updated_at = now() WHERE id = $1", case)
        log(case, t["node"], "skip", {"reason": reason.strip()})
        return {"case": case, "task": task, "status": "skipped"}
    raise ana.Error("INVALID_PARAMETER", "ação desconhecida")


def log(case, node, kind, detail):
    ana.sql_exec("INSERT INTO bpm.event (case_id, node, kind, by, detail) VALUES ($1, $2, $3, $4, $5)",
                 case, node, kind, ana.context.user, detail)
