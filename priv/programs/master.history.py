# ana:description Cadastros: histórico campo a campo de um registro mestre (quem, quando, antes e depois)
# ana:exposed yes
# ana:category Cadastros/Dados mestres
"""Spec 040 (RF-040-06)."""

from ana_lib.master import core

PARAMS = {"entity": {"type": "str", "required": True, "label": "cadastro"},
          "key": {"type": "str", "required": True, "label": "código"}}


def main(entity, key):
    rows = core.history(entity, key)
    ana.table([{"quando": r["at"], "campo": r["field"], "antes": r["before"], "depois": r["after"], "por": r["by"],
                "origem": r["origin"]} for r in rows], title="Histórico")
    return {"entity": entity, "key": key, "changes": rows}
