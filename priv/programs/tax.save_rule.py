# ana:description Cria ou edita uma regra de imposto em rascunho (critérios, fórmulas e vigência)
# ana:exposed yes
# ana:category Fiscal/Regras e pacotes
"""Draft rules (spec 049, RF-049-02/04). Formulas are validated when saved (CA-049-05); the rule only
changes calculations after "Ativar", which runs the test cases."""

from ana_lib.tax import admin, engine

PARAMS = {
    "rule": {"type": "int", "label": "regra em rascunho (vazio = nova)"},
    "tax": {"type": "str", "label": "tributo", "lookup": {"program": "tax.lookup", "params": {"kind": "taxes"}}},
    "name": {"type": "str", "label": "nome da regra"},
    "valid_from": {"type": "date", "label": "vale a partir de"},
    "valid_to": {"type": "date", "label": "vale até (vazio = sem fim)"},
    "criteria": {"type": "dict", "label": "critérios ({\"emitter.regime\": \"simples\", \"item.ncm\": {\"prefix\": \"85\"}})"},
    "formulas": {"type": "list", "label": "fórmulas, na ordem ([[\"base\", \"amount\"], [\"rate\", \"0.05\"], [\"amount\", \"round(base * rate, 2)\"]])"},
}


def main(rule=None, tax=None, name=None, valid_from=None, valid_to=None, criteria=None, formulas=None):
    admin.require_tax()
    if rule:
        cur = admin.get_rule(rule, lock=True)
        if cur["status"] != "draft":
            raise ana.Error("TAX_RULE_ACTIVE", f"regra {rule} já está {cur['status']}: use Nova vigência para mudá-la")
        new = {"tax": tax or cur["tax"], "name": name or cur["name"], "valid_from": valid_from or cur["valid_from"],
               "valid_to": valid_to if valid_to is not None else cur["valid_to"],
               "criteria": criteria if criteria is not None else cur["criteria"],
               "formulas": formulas if formulas is not None else cur["formulas"]}
    else:
        if not (tax and name and valid_from and formulas):
            raise ana.ParamError("informe tributo, nome, início da vigência e fórmulas")
        new = {"tax": tax, "name": name, "valid_from": valid_from, "valid_to": valid_to, "criteria": criteria or {},
               "formulas": formulas}
    admin.check_rule(new)
    args = (new["tax"], new["name"], engine.as_date(new["valid_from"]),
            None if new["valid_to"] is None else engine.as_date(new["valid_to"]),
            engine.canonical(new["criteria"]), engine.canonical(new["formulas"]))
    if rule:
        ana.sql_exec("UPDATE tax.rule SET tax = $2, name = $3, valid_from = $4, valid_to = $5, criteria = $6::text::jsonb, "
                     "formulas = $7::text::jsonb WHERE id = $1", int(rule), *args)
        rid = int(rule)
    else:
        rid = ana.sql_value("INSERT INTO tax.rule (tax, name, valid_from, valid_to, criteria, formulas, created_by) "
                            "VALUES ($1, $2, $3, $4, $5::text::jsonb, $6::text::jsonb, $7) RETURNING id", *args, ana.context.user)
    ana.actions([{"label": "Ativar (roda os casos de teste)", "program": "tax.activate_rule", "params": {"rule": rid}, "open": True},
                 {"label": "Ver a regra", "program": "tax.rule", "params": {"rule": rid}, "open": True}],
                title=f"Regra {rid} salva em rascunho")
    return {"rule": rid, "status": "draft"}
