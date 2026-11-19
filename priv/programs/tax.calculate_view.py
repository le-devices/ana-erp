# ana:description Apresentação do resultado do motor de impostos (totais, por tributo e "por que este imposto?")
# ana:kind library
"""Shared view of a tax result (spec 049, P18): totals, per tax and the plain-language explanation."""

from ana_lib.tax import engine
from ana_lib.util.format import money


def _pct(rate):
    return f"{rate * 100:.4f}".rstrip("0").rstrip(".").replace(".", ",") + "%"


def show(r, title="Impostos calculados"):
    ana.metrics([{"label": "Total do documento", "value": money(r["total"])},
                 {"label": "Tributos do emitente", "value": money(r["totals"]["amount"])},
                 {"label": "Retido pelo tomador", "value": money(r["totals"]["withheld"])},
                 {"label": "Cobrado além do preço", "value": money(r["totals"].get("charged", 0))},
                 {"label": "Líquido a receber", "value": money(r["net"])}], title=title)
    ana.table([{"tributo": t["name"], "base": money(t.get("base", 0)),
                "alíquota": _pct(t["rate"]) if t.get("rate") is not None else "",
                "valor": money(t.get("amount", 0)), "retido": money(t.get("withheld", 0)),
                "cobrado": money(t.get("charged", 0))} for t in r["taxes"]]
              or [{"tributo": "nenhum tributo se aplica", "base": "", "alíquota": "", "valor": "", "retido": "", "cobrado": ""}],
              title="Por tributo")
    ana.table([{"por que": line} for line in engine.explain_text(r)]
              or [{"por que": "nenhuma regra vale para este documento"}], title="Por que este imposto?")
