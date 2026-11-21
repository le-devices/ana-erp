# ana:description Retira uma regra de imposto (deixa de valer; o histórico fica)
# ana:exposed yes
# ana:menu no
# ana:category Fiscal/Regras e pacotes
"""Retire a rule (spec 049): it stops applying; past calculations keep their record."""

from ana_lib.tax import admin

PARAMS = {
    "rule": {"type": "int", "required": True, "label": "regra"},
    "reason": {"type": "str", "required": True, "label": "motivo"},
}


def main(rule, reason):
    admin.require_tax()
    r = admin.get_rule(rule, lock=True)
    if r["status"] == "draft":
        ana.sql_exec("DELETE FROM tax.rule WHERE id = $1", r["id"])
        return {"rule": r["id"], "deleted": True}
    ana.sql_exec("UPDATE tax.rule SET status = 'retired', reason = $2 WHERE id = $1", r["id"], reason)
    ana.sql_exec("INSERT INTO tax.change (kind, target, reason, username) VALUES ('retire', $1, $2, $3)",
                 f"rule:{r['id']}", reason, ana.context.user)
    return {"rule": r["id"], "retired": True}
