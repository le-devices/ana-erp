# ana:description Cadastros: busca padrão de qualquer entidade mestre (texto, filtros, ativos/inativos, páginas)
# ana:exposed yes
"""Spec 040 (RF-040-02). The same list for every entity."""

from ana_lib.master import core

PARAMS = {
    "entity": {"type": "str", "required": True, "label": "cadastro"},
    "q": {"type": "str", "label": "buscar"},
    "filters": {"type": "dict", "label": "filtros"},
    "active": {"type": "str", "default": "true", "label": "situação", "choices": [["true", "Ativos"], ["false", "Inativos"], ["all", "Todos"]]},
    "offset": {"type": "int", "default": 0, "label": "a partir de"},
    "limit": {"type": "int", "default": 50, "label": "quantos"},
}


def main(entity, q=None, filters=None, active="true", offset=0, limit=50):
    return core.search(entity, q, filters, active, offset, limit)
