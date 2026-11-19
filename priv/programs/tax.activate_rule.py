# ana:description Ativa uma regra: valida, recusa conflitos, roda os casos de teste e mostra o que muda
# ana:exposed yes
# ana:category Fiscal/Regras e pacotes
"""Activation (spec 049, CA-049-03, CA-049-04, RNF-049-03): without differences in the test cases it activates
directly; with differences it shows them and only proceeds with confirmation and a reason."""

from ana_lib.tax import admin
from ana_lib.tax.activate_view import show_differences

PARAMS = {
    "rule": {"type": "int", "required": True, "label": "regra", "lookup": {"program": "tax.lookup", "params": {"kind": "rules"}}},
    "reason": {"type": "str", "required": True, "label": "motivo (ex.: lei, decreto, orientação do contador)"},
    "confirm": {"type": "bool", "default": False, "label": "confirmo as diferenças mostradas nos casos de teste"},
}


def main(rule, reason, confirm=False):
    r = admin.activate(rule, reason, confirm)
    show_differences(r["differences"])
    if not r["activated"]:
        ana.actions([{"label": "Confirmar e ativar", "program": "tax.activate_rule", "style": "primary",
                      "params": {"rule": rule, "reason": reason, "confirm": True}}],
                    title=f"{len(r['differences'])} caso(s) de teste mudam com esta regra: confira antes de ativar")
    return r
