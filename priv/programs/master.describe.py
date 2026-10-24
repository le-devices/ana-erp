# ana:description Cadastros: definição das entidades mestres (campos, abas, permissões) para a tela e para integrações
# ana:exposed yes
# ana:category Cadastros/Dados mestres
"""Spec 040 (RF-040-01). Only the entities and fields the user may see."""

from ana_lib.master import core
from ana_lib.master import entities

PARAMS = {"entity": {"type": "str", "label": "cadastro (vazio = todos)"}}


def main(entity=None):
    return {"groups": entities.GROUPS, "entities": core.describe(entity or None)}
