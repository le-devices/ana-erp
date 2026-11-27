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
    "event_ref": {"type": "str", "label": "evento (mudanças vigiadas)"},
}
# Spec 068 (D11): what goes out has a size limit; a long list is cut with "+N" at the end.
MAX_PAYLOAD = 64 * 1024


def main(action, facts=None, rule=None, rule_name=None, entity=None, key=None, event_ref=None):
    if ana.context.origin != "internal":
        raise ana.Error("FORBIDDEN", "só o núcleo executa a ação de uma regra (ela roda quando a regra dispara)")
    kind = action.get("kind")
    origin = f"Regra \"{rule_name}\"" if rule_name else "Regra"
    if kind == "task":
        task = ana.sql_value(
            "SELECT automation.create_task($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb, $11::jsonb, "
            "  $12::jsonb, NULL, $13, $14, $15)",
            action["name"], action.get("task_kind", "human"), entity, key, action.get("assignee") or None,
            action.get("role") or None, action.get("group") or None,
            ((action.get("instructions") or "") + f"\n\n{origin}.").strip(), action.get("program") or None,
            action.get("params") or {}, facts or {}, action.get("actions") or [],
            int(action.get("priority") or 3), ana.context.user,
            # Spec 068 (CA-068-01): a check of a change is done by someone else — set when the task is born, refused
            # by the database to the one who changed it.
            (facts or {}).get("changed_by") if action.get("not_by_changer") else None)
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
        payload = _limited(payload)
        # Spec 068 (D11): queued once per event (a firing taken again finds it queued), in order per record.
        event_id = f"rule:{rule}:{event_ref}" if (rule and event_ref) else None
        return {"message": ana.send(action["connector"], action["message_kind"], payload,
                                    key=f"rule-{rule}-{entity}-{key}", event_id=event_id)}
    raise ana.Error("INVALID_PARAMETER", f"ação desconhecida: {kind}")


def _limited(payload):
    """Cuts the longest lists until the message fits MAX_PAYLOAD, saying how many were left out."""
    import json
    size = lambda p: len(json.dumps(p, ensure_ascii=False, default=str).encode("utf-8"))  # noqa: E731
    if size(payload) <= MAX_PAYLOAD:
        return payload
    out = json.loads(json.dumps(payload, default=str))
    for _ in range(20):
        lists = []
        def walk(node):
            if isinstance(node, dict):
                for v in node.values():
                    walk(v)
            elif isinstance(node, list):
                lists.append(node)
                for v in node:
                    walk(v)
        walk(out)
        if not lists or size(out) <= MAX_PAYLOAD:
            break
        longest = max(lists, key=len)
        if len(longest) <= 1:
            break
        keep = len(longest) // 2
        cut = len(longest) - keep
        del longest[keep:]
        longest.append(f"+{cut}")
    out["truncated"] = True
    return out
