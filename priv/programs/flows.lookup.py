# ana:description Opções para campos das esteiras
# ana:menu no
"""Lookup: [{"value", "label"}] of the flows (active first)."""

PARAMS = {"kind": {"type": "str", "default": "flows", "label": "tipo", "choices": ["flows"]}}


def main(kind="flows"):
    rows = ana.sql("SELECT code, name, active FROM flow.definition ORDER BY active DESC, name")
    return [{"value": r["code"], "label": r["name"] + ("" if r["active"] else " (desligada)")} for r in rows]
