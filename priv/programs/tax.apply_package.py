# ana:description Aplica um pacote de regras de impostos (atualização do produto): roda os casos e mostra o que muda
# ana:exposed yes
# ana:category Fiscal/Regras e pacotes
"""Rule packages (spec 049, D5, RF-049-06, CA-049-04): the package arrives as a product update (spec 028);
applying it compares with what is active, runs the company's test cases with both and asks for confirmation
when something changes. Nothing is applied without the tax officer."""

from ana_lib.tax import admin
from ana_lib.tax.activate_view import show_differences

PARAMS = {
    "package": {"type": "str", "required": True, "label": "pacote",
                "lookup": {"program": "tax.lookup", "params": {"kind": "packages"}}},
    "reason": {"type": "str", "required": True, "label": "motivo (ex.: atualização do produto de novembro)"},
    "confirm": {"type": "bool", "default": False, "label": "confirmo as diferenças mostradas nos casos de teste"},
}


def main(package, reason, confirm=False):
    st = admin.package_status(package)
    ana.log(st["notice"] or st["title"], "warning")
    r = admin.apply_package(package, reason, confirm)
    show_differences(r["differences"])
    if not r["applied"]:
        ana.actions([{"label": "Confirmar e aplicar", "program": "tax.apply_package", "style": "primary",
                      "params": {"package": package, "reason": reason, "confirm": True}}],
                    title=f"{len(r['differences'])} caso(s) de teste mudam com o pacote: confira antes de aplicar")
        return r
    if r["case_failures"]:
        ana.table([{"caso": c["name"], "não confere": "; ".join(c["failures"])} for c in r["case_failures"]],
                  title="Casos que não conferem com o esperado")
    ana.actions([{"label": "Ver os tributos", "program": "tax.overview", "open": True},
                 {"label": "Rodar os casos de teste", "program": "tax.run_cases", "open": True}],
                title=f"Pacote {r['package']} {r['version']} aplicado: {r['rules_new']} regra(s) nova(s), {r['rules_retired']} retirada(s)")
    return r
