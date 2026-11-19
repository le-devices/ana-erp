# ana:description Caso de teste tributário: um documento e o resultado esperado, rodado antes de toda mudança
# ana:exposed yes
# ana:category Fiscal/Casos de teste
"""Company test cases (spec 049, D6, RF-049-05). With `from_calculation`, the case starts from a real
calculation (e.g. last month's invoice) and the expected result is what it gave."""

import json

from ana_lib.tax import admin, engine

PARAMS = {
    "case": {"type": "int", "label": "caso (vazio = novo)", "lookup": {"program": "tax.lookup", "params": {"kind": "cases"}}},
    "name": {"type": "str", "label": "nome (ex.: venda de protótipo para indústria em SP)"},
    "document": {"type": "dict", "label": "documento"},
    "expected": {"type": "dict", "label": "esperado ({\"taxes\": {\"iss\": {\"amount\": \"50.00\"}}, \"totals\": {...}})"},
    "from_calculation": {"type": "int", "label": "ou partir de um cálculo registrado"},
    "active": {"type": "bool", "default": True, "label": "ativo"},
}


def main(case=None, name=None, document=None, expected=None, from_calculation=None, active=True):
    admin.require_tax()
    if from_calculation:
        c = ana.sql_one("SELECT input, result FROM tax.calculation WHERE id = $1", from_calculation)
        if not c:
            raise ana.Error("NOT_FOUND", f"cálculo {from_calculation} não encontrado")
        inp = json.loads(c["input"]) if isinstance(c["input"], str) else c["input"]
        res = json.loads(c["result"]) if isinstance(c["result"], str) else c["result"]
        document = {"operation": inp["doc"].get("operation"), "date": inp["date"], "emitter": inp["emitter"],
                    "recipient": inp["recipient"], "items": [{"amount": i["amount"], "attributes": i["attributes"]} for i in inp["items"]],
                    "indicators": res.get("indicators") or {}}
        expected = {"taxes": {t["tax"]: {k: t[k] for k in ("amount", "withheld", "credit") if k in t} for t in res["taxes"]},
                    "totals": res["totals"]}
        name = name or f"Cálculo {from_calculation} ({inp['date']})"
    if not (name and document):
        raise ana.ParamError("informe nome e documento (ou um cálculo registrado)")
    got = admin.run_case({"document": document}, engine.load())
    if case:
        ana.sql_exec("UPDATE tax.test_case SET name = $2, document = $3::text::jsonb, expected = $4::text::jsonb, active = $5, "
                     "updated_at = now(), updated_by = $6 WHERE id = $1", case, name, engine.canonical(document),
                     engine.canonical(expected or {}), active, ana.context.user)
        cid = case
    else:
        cid = ana.sql_value("INSERT INTO tax.test_case (name, document, expected, active, updated_by) "
                            "VALUES ($1, $2::text::jsonb, $3::text::jsonb, $4, $5) RETURNING id",
                            name, engine.canonical(document), engine.canonical(expected or {}), active, ana.context.user)
    fails = admin.expected_failures({"expected": expected or {}}, got)
    ana.actions([{"label": "Rodar todos os casos", "program": "tax.run_cases", "open": True}],
                title=f"Caso {cid} salvo — " + ("confere com as regras de hoje" if not fails else "; ".join(fails)))
    return {"case": cid, "now": got, "failures": fails}
