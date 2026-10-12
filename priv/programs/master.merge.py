# ana:description Cadastros: mescla dois registros duplicados (move pedidos, títulos e demais referências; desativa o duplicado)
# ana:exposed yes
# ana:role admin
"""Spec 040 (RF-040-07, CA-040-03). One transaction; refused, saying where, when a reference cannot move."""

from ana_lib.master import core

PARAMS = {"entity": {"type": "str", "required": True, "label": "cadastro"},
          "keep": {"type": "str", "required": True, "label": "fica (código)"},
          "drop": {"type": "str", "required": True, "label": "sai (código do duplicado)"},
          "reason": {"type": "str", "required": True, "label": "motivo"}}


def main(entity, keep, drop, reason):
    return core.merge(entity, keep, drop, reason)
