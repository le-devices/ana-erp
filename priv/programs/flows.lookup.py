# ana:description Opções para campos das esteiras
# ana:menu no
"""Lookup: [{"value", "label"}] of the flows (active first), the steps of a flow and the fields of its
documents (for the condition builder: [{"name", "label", "type"}], spec 020 RF-020-14)."""

from ana_lib.flows import common

PARAMS = {"kind": {"type": "str", "default": "flows", "label": "tipo", "choices": ["flows", "steps", "facts"]},
          "flow": {"type": "str", "label": "esteira"}}


def main(kind="flows", flow=None):
    if kind == "steps":
        rows = ana.sql("SELECT seq, name, mode FROM flow.step WHERE flow_code = $1 ORDER BY seq", flow)
        return [{"value": r["seq"], "label": f"{r['seq']}. {r['name']} ({common.MODE[r['mode']]})"} for r in rows]
    if kind == "facts":
        return common.fact_fields(flow) if flow else []
    rows = ana.sql("SELECT code, name, active FROM flow.definition ORDER BY active DESC, name")
    return [{"value": r["code"], "label": r["name"] + ("" if r["active"] else " (desligada)")} for r in rows]
