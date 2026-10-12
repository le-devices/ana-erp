# ana:description Cadastros: apaga um registro mestre que nunca foi usado (senão, diz onde está em uso)
# ana:exposed yes
"""Spec 040 (RF-040-05, CA-040-04)."""

from ana_lib.master import core

PARAMS = {"entity": {"type": "str", "required": True, "label": "cadastro"},
          "key": {"type": "str", "required": True, "label": "código"}}


def main(entity, key):
    return core.delete(entity, key)
