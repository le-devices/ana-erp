# ana:description Cadastros: desativa ou reativa registros mestres (um ou vários); inativos saem das buscas de uso
# ana:exposed yes
# ana:category Cadastros/Dados mestres
"""Spec 040 (RF-040-05). Old documents keep pointing to inactive records; new ones refuse them."""

from ana_lib.master import core

PARAMS = {"entity": {"type": "str", "required": True, "label": "cadastro"},
          "keys": {"type": "list", "required": True, "label": "códigos"},
          "active": {"type": "bool", "default": False, "label": "ativo"}}


def main(entity, keys, active=False):
    return core.set_active(entity, [str(k) for k in keys], active)
