# ana:description Informa o valor de um atributo fiscal com vigência (ex.: regime da empresa a partir de 2027)
# ana:exposed yes
# ana:category Fiscal/Cadastros fiscais
"""Attribute values with validity (spec 049, D11, CA-049-09): the value open until today is closed on the
day before the new one starts, so the history stays and each date reads its own value."""

import datetime

from ana_lib.tax import admin

ENTITY_SQL = {"company": "SELECT id::text FROM base.company ORDER BY id LIMIT 1",
              "party": "SELECT id::text FROM base.party WHERE id::text = $1",
              "item": "SELECT code FROM base.product WHERE code = upper($1)",
              "contract": "SELECT code FROM projects.project WHERE code = upper($1)"}
PARAMS = {
    "attribute": {"type": "str", "required": True, "label": "atributo",
                  "lookup": {"program": "tax.lookup", "params": {"kind": "attributes"}}},
    "target": {"type": "str", "label": "pessoa (id), item ou projeto (código); vazio para a empresa"},
    "value": {"type": "str", "label": "valor (vazio = sem valor a partir da data)"},
    "valid_from": {"type": "date", "required": True, "label": "vale a partir de"},
}


def main(attribute, valid_from, target=None, value=None):
    admin.require_tax()
    entity, _, code = attribute.partition(".")
    a = ana.sql_one("SELECT value_type, code_list FROM tax.attribute WHERE entity = $1 AND code = $2", entity, code)
    if not a:
        raise ana.ParamError(f"atributo {attribute} não cadastrado")
    ident = ana.sql_value(ENTITY_SQL[entity], *([] if entity == "company" else [str(target or "")]))
    if not ident:
        raise ana.ParamError(f"{entity} {target} não encontrado")
    if value not in (None, "") and a["code_list"] and not ana.sql_value(
            "SELECT EXISTS (SELECT 1 FROM tax.code WHERE list = $1 AND code = $2)", a["code_list"], value):
        raise ana.ParamError(f"{value} não está na lista {a['code_list']}")
    ana.sql_exec("UPDATE tax.attribute_value SET valid_to = $5 WHERE entity = $1 AND entity_id = $2 AND attribute = $3 "
                 "AND COALESCE(valid_from, '-infinity') < $4 AND (valid_to IS NULL OR valid_to >= $4)",
                 entity, ident, code, valid_from, valid_from - datetime.timedelta(days=1))
    ana.sql_exec("DELETE FROM tax.attribute_value WHERE entity = $1 AND entity_id = $2 AND attribute = $3 AND valid_from >= $4",
                 entity, ident, code, valid_from)
    ana.sql_exec("INSERT INTO tax.attribute_value (entity, entity_id, attribute, value, valid_from, updated_by) "
                 "VALUES ($1, $2, $3, $4, $5, $6)", entity, ident, code, value if value != "" else None, valid_from,
                 ana.context.user)
    return {"attribute": attribute, "target": ident, "value": value, "valid_from": valid_from}
