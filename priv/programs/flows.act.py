# ana:description Age numa etapa da esteira: reprocessar, executar agora ou pular (com motivo)
# ana:menu no
"""RF-030-05. Every action is recorded with who and why (the functions of the flow schema
check the state and move the flow on)."""

PARAMS = {
    "instance": {"type": "int", "required": True, "label": "instância"},
    "seq": {"type": "int", "required": True, "label": "etapa"},
    "action": {"type": "str", "required": True, "label": "ação",
               "choices": [["retry", "Reprocessar"], ["run", "Executar agora"], ["skip", "Pular"]]},
    "reason": {"type": "str", "label": "motivo (para pular)"},
}


def main(instance, seq, action, reason=None):
    if action == "skip":
        ana.sql("SELECT flow.skip($1, $2, $3, $4)", instance, seq, ana.context.user, reason or "")
        ana.log(f"etapa {seq} da instância {instance} pulada: {reason}")
    elif action in ("retry", "run"):
        ana.sql("SELECT flow.retry($1, $2, $3, $4)", instance, seq, ana.context.user, action == "run")
    else:
        raise ana.Error("INVALID_PARAMETER", f"ação desconhecida: {action}")
    return {"instance": instance, "seq": seq, "action": action}
