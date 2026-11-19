# ana:description Calcula os impostos de um documento pelas regras vigentes e explica por quê
# ana:exposed yes
# ana:command imposto
# ana:category Fiscal/Cálculo e simulação
"""Tax service for the API and other systems (spec 049, D1, RF-049-01). Calculates only: nothing is recorded.

document: {"operation": "service_sale", "date": "2026-11-19", "recipient": <party id or attributes>,
           "contract": "<project code>", "items": [{"code", "description", "quantity", "unit_price", "attributes"}],
           "indicators": {"<code>": "<value>"} (optional: fixed values for a simulation)}
"""

from ana_lib.tax import calculate_view, engine

PARAMS = {
    "document": {"type": "dict", "required": True, "label": "documento (operação, data, destinatário, itens)"},
}


def main(document):
    try:
        r = engine.calculate(document)
    except engine.TaxError as e:
        raise ana.Error(e.code, e.message) from None
    calculate_view.show(r)
    return r
