# ana:description Técnico sai para o atendimento (OS a caminho)
# ana:exposed yes
"""RF-015-08. Records the first response for the SLA indicators."""

from ana_lib.field import common

PARAMS = {"order": {"type": "int", "required": True, "label": "OS"}}


def main(order):
    o = common.order(order, lock=True)
    common.require_open(o)
    common.advance(o, "en_route")
    return {"order": o["number"], "status": "en_route"}
