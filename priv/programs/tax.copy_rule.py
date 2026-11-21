# ana:description Nova vigência de uma regra: copia com nova data; ao ativar, a anterior termina na véspera
# ana:exposed yes
# ana:category Fiscal/Regras e pacotes
"""Mudou a lei: a new validity from an existing rule (spec 049, D2, RF-049-02). Nothing old is edited."""

from ana_lib.tax import admin

PARAMS = {
    "rule": {"type": "int", "required": True, "label": "regra", "lookup": {"program": "tax.lookup", "params": {"kind": "rules"}}},
    "valid_from": {"type": "date", "required": True, "label": "nova vigência a partir de"},
    "formulas": {"type": "list", "label": "fórmulas novas (vazio = as mesmas)"},
    "criteria": {"type": "dict", "label": "critérios novos (vazio = os mesmos)"},
    "name": {"type": "str", "label": "nome (vazio = o mesmo)"},
}


def main(rule, valid_from, formulas=None, criteria=None, name=None):
    rid = admin.copy_with_date(rule, valid_from, formulas, criteria, name)
    ana.sql_exec("INSERT INTO tax.change (kind, target, reason, username) VALUES ('copy', $1, $2, $3)",
                 f"rule:{rid}", f"nova vigência da regra {rule} a partir de {valid_from:%d/%m/%Y}", ana.context.user)
    ana.actions([{"label": "Ativar (roda os casos de teste)", "program": "tax.activate_rule", "params": {"rule": rid}, "open": True}],
                title=f"Rascunho {rid}: vale a partir de {valid_from:%d/%m/%Y}")
    return {"rule": rid, "copied_from": rule}
