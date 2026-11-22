# ana:description Automação: faz a ação de uma regra "quando… então…" (tarefa, aviso, e-mail ou conector) — chamada pelo núcleo
# ana:menu no
# ana:category Administração/Automações
"""Spec 051 (D2, RF-051-02). The core runs it as the rule's owner when the rule fires (or rehearses it): the action of
the closed list, in the routine's own transaction — a rehearsal undoes the task and the notice and holds the e-mail and
the message to the connector, listing them. Only the core calls it (origin "internal")."""

PARAMS = {
    "action": {"type": "dict", "required": True, "label": "ação"},
    "facts": {"type": "dict", "label": "fatos do documento"},
    "rule": {"type": "int", "label": "regra"},
    "rule_name": {"type": "str", "label": "nome da regra"},
    "entity": {"type": "str", "label": "documento"},
    "key": {"type": "str", "label": "número do documento"},
}


def main(action, facts=None, rule=None, rule_name=None, entity=None, key=None):
    if ana.context.origin != "internal":
        raise ana.Error("FORBIDDEN", "só o núcleo executa a ação de uma regra (ela roda quando a regra dispara)")
    kind = action.get("kind")
    origin = f"Regra \"{rule_name}\"" if rule_name else "Regra"
    if kind == "task":
        task = ana.sql_value(
            "SELECT automation.create_task($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb, $11::jsonb, "
            "  $12::jsonb, NULL, $13, $14)",
            action["name"], action.get("task_kind", "human"), entity, key, action.get("assignee") or None,
            action.get("role") or None, action.get("group") or None,
            ((action.get("instructions") or "") + f"\n\n{origin}.").strip(), action.get("program") or None,
            action.get("params") or {}, facts or {}, action.get("actions") or [],
            int(action.get("priority") or 3), ana.context.user)
        return {"task": task}
    if kind == "notify":
        n = ana.sql_value("SELECT automation.notify($1, $2, $3)", action.get("user") or None, action.get("group") or None,
                          f"{action['message']} ({origin})")
        if not n:
            raise ana.Error("INVALID_PARAMETER", "ninguém recebeu o aviso: confira a pessoa ou o grupo da regra")
        return {"notified": n}
    if kind == "email":
        text = (action.get("text") or "") + f"\n\n— {origin}, ANA ERP"
        return {"email": ana.send_email(action["to"], action["subject"], text=text, connector=action.get("connector"))}
    if kind == "connector":
        payload = dict(action.get("payload") or {})
        payload.setdefault("document", {"entity": entity, "key": key})
        payload.setdefault("facts", facts or {})
        return {"message": ana.send(action["connector"], action["message_kind"], payload, key=f"rule-{rule}-{entity}-{key}")}
    raise ana.Error("INVALID_PARAMETER", f"ação desconhecida: {kind}")
