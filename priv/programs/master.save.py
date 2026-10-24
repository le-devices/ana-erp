# ana:description Cadastros: salva um registro mestre (validação padrão, duplicados, versão, aprovação de campos sensíveis)
# ana:exposed yes
# ana:category Cadastros/Dados mestres
"""Spec 040 (RF-040-03, 07, 08). Without key: creates. values: {field: value}; tabs: {tab label: values or
rows}; version: the one read with master.get (refused when someone changed it meanwhile)."""

from ana_lib.master import core

PARAMS = {
    "entity": {"type": "str", "required": True, "label": "cadastro"},
    "key": {"type": "str", "label": "código (vazio = novo)"},
    "values": {"type": "dict", "label": "campos"},
    "tabs": {"type": "dict", "label": "abas"},
    "version": {"type": "str", "label": "versão lida"},
    "confirm_duplicate": {"type": "bool", "default": False, "label": "não é duplicado"},
    "reason": {"type": "str", "label": "motivo"},
}


def main(entity, key=None, values=None, tabs=None, version=None, confirm_duplicate=False, reason=None):
    return core.save(entity, key, values, tabs, version, confirm_duplicate, reason)
