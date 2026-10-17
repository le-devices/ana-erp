# ana:description Processos: avisos de tarefas (nova, perto do prazo, atrasada) da pessoa conectada
# ana:exposed yes
"""Spec 039 (RF-039-12)."""

PARAMS = {"read": {"type": "list", "label": "marcar como lidos (ids; vazio = nenhum)"},
          "all_read": {"type": "bool", "default": False, "label": "marcar todos como lidos"}}


def main(read=None, all_read=False):
    if all_read:
        ana.sql_exec("UPDATE bpm.notification SET read = true WHERE username = $1 AND NOT read", ana.context.user)
    elif read:
        ana.sql_exec("UPDATE bpm.notification SET read = true WHERE username = $1 AND id = ANY($2)", ana.context.user,
                     [int(x) for x in read])
    return {"notifications": ana.sql("SELECT id, task_id, case_id, kind, message, read, created_at FROM bpm.notification "
                                     "WHERE username = $1 ORDER BY id DESC LIMIT 100", ana.context.user)}
