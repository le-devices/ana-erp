# ana:description Cadastros: busca única para campos de escolha (registros ativos, mesmo texto e ordem em todo o ERP)
# ana:exposed yes
# ana:category Cadastros/Dados mestres
"""Spec 040 (RF-040-04)."""

from ana_lib.master import core

PARAMS = {
    "entity": {"type": "str", "required": True, "label": "cadastro"},
    "q": {"type": "str", "label": "buscar"},
    "by": {"type": "str", "default": "key", "label": "valor", "choices": [["key", "Código"], ["id", "Identificador"]]},
    "field": {"type": "str", "label": "campo que pede a escolha (aplica o filtro dele)"},
    "of": {"type": "str", "label": "cadastro do campo"},
}


def main(entity, q=None, by="key", field=None, of=None):
    flt = None
    if field and of:
        d = core.entity(of)
        f = next((x for x in d["fields"] + [y for t in d["tabs"] for y in t.get("fields", [])] if x["name"] == field), None)
        flt = f and f.get("filter")
    return core.options(entity, q, by=by, filter_sql=flt)
