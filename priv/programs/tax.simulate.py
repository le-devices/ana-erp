# ana:description Simulação: como ficariam os impostos de um documento numa data (ex.: com as regras de 2027)
# ana:exposed yes
# ana:command simularimposto
# ana:category Fiscal/Cálculo e simulação
"""Rehearsal by date (spec 049, D6, P18/P19 — spec 056): recalculates an informed document or an already
recorded calculation (e.g. an invoice) on another date, with optional fixed indicators, and shows what changes.
Writes nothing."""

import json

from ana_lib.tax import calculate_view, engine
from ana_lib.util.format import money

PARAMS = {
    "on": {"type": "date", "required": True, "label": "calcular como se fosse em"},
    "calculation": {"type": "int", "label": "cálculo já registrado (ex.: de uma fatura)"},
    "document": {"type": "dict", "label": "ou um documento (operação, destinatário, itens)"},
    "indicators": {"type": "dict", "label": "indicadores fixos (ex.: {\"rbt12\": \"500000\"})"},
}


def main(on, calculation=None, document=None, indicators=None):
    before = None
    if calculation:
        c = ana.sql_one("SELECT input, result FROM tax.calculation WHERE id = $1", calculation)
        if not c:
            raise ana.Error("NOT_FOUND", f"cálculo {calculation} não encontrado")
        inp = json.loads(c["input"]) if isinstance(c["input"], str) else c["input"]
        before = json.loads(c["result"]) if isinstance(c["result"], str) else c["result"]
        # The registry is read again on the simulated date (regime, attributes); only the items are kept.
        document = {"operation": inp["doc"].get("operation"), "recipient": inp["recipient"].get("id") or inp["recipient"],
                    "contract": inp["contract"].get("code"),
                    "items": [{"amount": i["amount"], "quantity": i["quantity"], "unit_price": i["unit_price"],
                               "attributes": i["attributes"]} for i in inp["items"]]}
    if not document:
        raise ana.ParamError("informe um cálculo registrado ou um documento")
    document = {**document, "date": on.isoformat()}
    if indicators:
        document["indicators"] = indicators
    try:
        r = engine.calculate(document)
    except engine.TaxError as e:
        raise ana.Error(e.code, e.message) from None
    calculate_view.show(r, title=f"Simulação em {on:%d/%m/%Y}")
    if before:
        old = {t["tax"]: t for t in before["taxes"]}
        new = {t["tax"]: t for t in r["taxes"]}
        ana.table([{"tributo": (new.get(k) or old.get(k))["name"],
                    "registrado": money(old.get(k, {}).get("amount", 0) or old.get(k, {}).get("withheld", 0)),
                    "simulado": money(new.get(k, {}).get("amount", 0) or new.get(k, {}).get("withheld", 0))}
                   for k in sorted(set(old) | set(new))], title=f"Registrado em {before['date']} × simulado")
    return r
