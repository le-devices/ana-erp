# ana:description Qual regra vale? Mostra, para um caso informado, as regras candidatas de cada tributo e a escolhida
# ana:exposed yes
# ana:category Fiscal/Cálculo e simulação
"""'Qual regra vale?' (spec 049, RF-049-03): every candidate rule per tax and item, its specificity, and why
the chosen one wins — or the conflict, when two tie."""

from ana_lib.tax import engine

PARAMS = {
    "document": {"type": "dict", "required": True, "label": "caso (operação, data, destinatário, itens)"},
}


def main(document):
    data = engine.load()
    try:
        doc = engine.normalize(document, data)
    except engine.TaxError as e:
        raise ana.Error(e.code, e.message) from None
    day = engine.as_date(doc["date"])
    rows = []
    base = {}
    for p in ("doc", "emitter", "recipient", "contract"):
        base.update({f"{p}.{k}": v for k, v in doc[p].items()})
    for i, it in enumerate(doc["items"]):
        env = dict(base)
        env.update({f"item.{k}": v for k, v in it["attributes"].items()})
        for t in data.taxes:
            cands = [r for r in data.rules_of(t["code"]) if engine.valid_on(r, day) and engine.criteria_match(r.get("criteria"), env)]
            try:
                chosen = engine.choose(data.rules_of(t["code"]), env, day)
                verdict = None
            except engine.TaxError as e:
                chosen, verdict = None, e.message
            for r in sorted(cands, key=lambda r: engine.specificity(r.get("criteria")), reverse=True):
                rows.append({"item": i + 1, "tributo": t["name"], "regra": f"{r['id']} {r['name']}",
                             "especificidade": "{} de entidade, {} critério(s), prefixo {}".format(*engine.specificity(r.get("criteria"))),
                             "resultado": "VALE" if chosen and chosen["id"] == r["id"] else (verdict or "menos específica")})
    ana.table(rows, title=f"Regras candidatas em {day:%d/%m/%Y}")
    if not rows:
        ana.actions([{"label": "Nova regra", "program": "tax.save_rule", "open": True}],
                    title="Nenhuma regra vale para este caso")
    return {"candidates": rows}
