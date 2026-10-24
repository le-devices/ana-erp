# ana:description Cadastros: painel de qualidade (incompletos, sem custo, sem fornecedor…), com os registros a corrigir
# ana:exposed yes
# ana:command qualidade_cadastros
# ana:category Cadastros/Dados mestres
"""Spec 040 (RF-040-10)."""

from ana_lib.master import core

PARAMS = {"entity": {"type": "str", "label": "cadastro (vazio = todos)"},
          "indicator": {"type": "str", "label": "indicador (lista os registros)"}}


def main(entity=None, indicator=None):
    if entity and indicator:
        rows = core.quality_rows(entity, indicator)
        ana.table([{"código": r["key"], "cadastro": r["title"]} for r in rows], title=indicator)
        return {"entity": entity, "indicator": indicator, "rows": rows}
    q = core.quality(entity or None)
    total = sum(i["count"] for e in q for i in e["items"])
    ana.metrics([{"label": "Pendências de qualidade", "value": total, "status": "ok" if not total else "warn"}])
    ana.table([{"cadastro": e["plural"], "indicador": i["label"], "registros": i["count"], "como corrigir": i["hint"],
                "_actions": [{"label": "Ver", "program": "master.quality", "params": {"entity": e["entity"], "indicator": i["label"]},
                              "open": True}] if i["count"] else []}
               for e in q for i in e["items"]], title="Qualidade dos cadastros")
    return {"entities": q, "pending": total}
