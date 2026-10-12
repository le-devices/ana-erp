# ana:description Cadastros: ficha de um registro mestre com abas, versão e pedidos de alteração pendentes
# ana:exposed yes
"""Spec 040 (RF-040-03)."""

from ana_lib.master import core

PARAMS = {"entity": {"type": "str", "required": True, "label": "cadastro"},
          "key": {"type": "str", "required": True, "label": "código"}}


def main(entity, key):
    return core.get(entity, key)
