# ana:description Cadastros: possíveis duplicados de um registro (mesmo documento, nome parecido, mesmo e-mail)
# ana:exposed yes
# ana:category Cadastros/Dados mestres
"""Spec 040 (RF-040-07)."""

from ana_lib.master import core

PARAMS = {"entity": {"type": "str", "required": True, "label": "cadastro"},
          "values": {"type": "dict", "label": "campos (novo cadastro)"},
          "key": {"type": "str", "label": "código (cadastro existente)"}}


def main(entity, values=None, key=None):
    exclude = None
    if key:
        rec = core.get(entity, key)
        values, exclude = rec["values"], rec["id"]
    return {"candidates": core.duplicates(entity, values or {}, exclude)}
