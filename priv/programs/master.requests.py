# ana:description Cadastros: pedidos de alteração de campos sensíveis (preço, limite de crédito, dados bancários) para aprovar ou recusar
# ana:exposed yes
# ana:command aprovar_cadastros
"""Spec 040 (RF-040-08, CA-040-05). Four eyes: whoever asked cannot decide (also checked by the database)."""

from ana_lib.master import core

PARAMS = {
    "id": {"type": "int", "label": "pedido"},
    "decision": {"type": "str", "label": "decisão", "choices": [["approve", "Aprovar"], ["reject", "Recusar"], ["cancel", "Cancelar (quem pediu)"]]},
    "reason": {"type": "str", "label": "motivo (obrigatório para recusar)"},
}


def main(id=None, decision=None, reason=None):
    if id and decision:
        return decide(id, decision, reason)
    rows = ana.sql("SELECT id, entity, row_key, title, changes, requested_by, requested_at FROM master.change_request "
                   "WHERE status = 'pending' ORDER BY id LIMIT 500")
    mine = [r for r in rows if core.can(core.entity(r["entity"]), "approve") or r["requested_by"] == ana.context.user]
    me = "master.requests"
    ana.table([{"pedido": r["id"], "cadastro": core.entity(r["entity"])["label"], "registro": r["title"],
                "alteração": "; ".join(f"{k}: {v[0] or '—'} → {v[1] or '—'}" for k, v in (r["changes"].get("diff") or {}).items()),
                "pedido por": r["requested_by"], "quando": r["requested_at"],
                "_actions": ([{"label": "Aprovar", "program": me, "style": "primary", "params": {"id": r["id"], "decision": "approve"}},
                              {"label": "Recusar", "program": me, "params": {"id": r["id"], "decision": "reject"},
                               "ask": {"reason": {"type": "str", "label": "motivo", "required": True}}}]
                             if r["requested_by"] != ana.context.user else
                             [{"label": "Cancelar", "program": me, "params": {"id": r["id"], "decision": "cancel"}}])}
               for r in mine], title="Alterações aguardando aprovação")
    return {"pending": len(mine), "rows": [{"id": r["id"], "entity": r["entity"], "label": core.entity(r["entity"])["label"],
                                            "title": r["title"], "diff": r["changes"].get("diff") or {}, "requested_by": r["requested_by"],
                                            "requested_at": r["requested_at"], "mine": r["requested_by"] == ana.context.user}
                                           for r in mine]}


def decide(rid, decision, reason):
    r = ana.sql_one("SELECT * FROM master.change_request WHERE id = $1 FOR UPDATE", rid)
    if not r or r["status"] != "pending":
        raise ana.Error("NOT_FOUND", f"pedido {rid} não está pendente")
    d = core.entity(r["entity"])
    key = ana.sql_value(f"SELECT t.{d['key']}::text FROM {d['table']} t WHERE t.{d['id']}::text = $1", r["row_key"])
    if decision == "cancel":
        if r["requested_by"] != ana.context.user and core.role() != "admin":
            raise ana.Error("FORBIDDEN", "só quem pediu (ou o administrador) cancela o pedido")
        ana.sql_exec("UPDATE master.change_request SET status = 'cancelled', decided_at = now() WHERE id = $1", rid)
        return {"id": rid, "status": "cancelled"}
    core.require(d, "approve")
    if r["requested_by"] == ana.context.user:
        raise ana.Error("SELF_APPROVAL", "a alteração precisa ser aprovada por outra pessoa")
    if decision == "reject":
        if len((reason or "").strip()) < 3:
            raise ana.Error("INVALID_PARAMETER", "diga o motivo da recusa")
        ana.sql_exec("UPDATE master.change_request SET status = 'rejected', decided_by = $2, decided_at = now(), reason = $3 "
                     "WHERE id = $1", rid, ana.context.user, reason.strip())
        ana.sql_exec("INSERT INTO master.change_log (entity, row_key, table_name, op, changes, username, origin) "
                     "VALUES ($1, $2, $3, 'reject', $4, $5, 'master')", r["entity"], r["row_key"], d["table"],
                     r["changes"].get("diff") or {}, ana.context.user)
        return {"id": rid, "status": "rejected"}
    c = r["changes"]
    rec = core.save(r["entity"], key, c.get("values"), c.get("tabs"), None, approved_request=rid)
    ana.sql_exec("UPDATE master.change_request SET status = 'applied', decided_by = $2, decided_at = now(), reason = $3 "
                 "WHERE id = $1", rid, ana.context.user, (reason or "").strip() or None)
    ana.sql_exec("INSERT INTO master.change_log (entity, row_key, table_name, op, changes, username, origin) "
                 "VALUES ($1, $2, $3, 'approve', $4, $5, 'master')", r["entity"], r["row_key"], d["table"],
                 {**(c.get("diff") or {}), "requested_by": [None, r["requested_by"]]}, ana.context.user)
    return {"id": rid, "status": "applied", "record": rec["key"]}
