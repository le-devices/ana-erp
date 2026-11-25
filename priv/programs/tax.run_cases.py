# ana:description Roda os casos de teste tributários com as regras de hoje e mostra o que não confere
# ana:exposed yes
# ana:category Fiscal/Casos de teste
"""Test cases (spec 049, D6): each case against the active rules; differences from the expected result."""

from ana_lib.tax import admin, engine

PARAMS = {}


def main():
    data = engine.load()
    rows, bad = [], 0
    for cid, (case, got) in admin.run_all(data).items():
        fails = admin.expected_failures(case, got)
        bad += bool(fails)
        rows.append({"caso": case["name"], "situação": "confere" if not fails else "NÃO CONFERE", "detalhe": "; ".join(fails),
                     "_actions": [{"label": "Editar", "program": "tax.save_case", "params": {"case": case["id"]}, "open": True}]})
    ana.metrics([{"label": "Casos", "value": len(rows)},
                 {"label": "Conferem", "value": len(rows) - bad, "status": "ok"},
                 {"label": "Não conferem", "value": bad, "status": "bad" if bad else "ok"}], title="Casos de teste tributários")
    ana.table(rows, title="Resultado por caso", empty="Nenhum caso cadastrado: crie um a partir de uma fatura real.",
              empty_action={"label": "Novo caso de teste", "program": "tax.save_case"})
    ana.actions([{"label": "Novo caso de teste", "program": "tax.save_case", "open": True}],
                title="Nenhum caso cadastrado: crie um a partir de uma fatura real" if not rows else None)
    return {"cases": len(rows), "failing": bad}
