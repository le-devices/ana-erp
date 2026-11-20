# ana:description Recalcula um cálculo de impostos já registrado e confere se dá o mesmo resultado
# ana:exposed yes
# ana:category Fiscal/Cálculo e simulação
"""Reproducibility (spec 049, RF-049-11, RNF-049-02, CA-049-02): the stored input, the rules valid on the date
of the fact and the indicators of the day give the same result. Writes nothing."""

import json
from decimal import Decimal

from ana_lib.tax import engine

PARAMS = {"calculation": {"type": "int", "required": True, "label": "cálculo"}}


def main(calculation):
    c = ana.sql_one("SELECT doc_kind, doc_ref, fact_date, input, result FROM tax.calculation WHERE id = $1", calculation)
    if not c:
        raise ana.Error("NOT_FOUND", f"cálculo {calculation} não encontrado")
    inp = json.loads(c["input"]) if isinstance(c["input"], str) else c["input"]
    old = json.loads(c["result"]) if isinstance(c["result"], str) else c["result"]
    for it in inp["items"]:
        for k in ("amount", "quantity", "unit_price", "discount"):
            it[k] = Decimal(str(it[k]))
    fixed = {k: Decimal(str(v)) for k, v in (old.get("indicators") or {}).items()}
    new = engine.compute(inp, engine.load(), lambda code: fixed[code], company_value=lambda name, at: ana.value(name, at=at))
    key = lambda r: [(t["tax"], str(t.get("amount", "0")), str(t.get("withheld", "0")), str(t.get("credit", "0")))
                     for t in r["taxes"]]
    same = engine.canonical(key(old)) == engine.canonical(key(new))
    ana.metrics([{"label": "Documento", "value": f"{c['doc_kind']} {c['doc_ref']}"},
                 {"label": "Data do fato", "value": str(c["fact_date"])},
                 {"label": "Resultado", "value": "igual ao registrado" if same else "DIFERENTE", "status": "ok" if same else "bad"}],
                title=f"Recálculo do cálculo {calculation}")
    return {"same": same, "recorded": old["totals"], "now": new["totals"]}
