# ana:description Impostos: situação das regras, pacotes, avisos e próximos passos
# ana:exposed yes
# ana:command impostos
# ana:category Fiscal/Regras e pacotes
"""Home of the tax area (spec 049, P18/P19): what needs attention first, then the taxes and their rules."""

from ana_lib.tax import admin

ME = "tax.overview"

PARAMS = {}


def main():
    alerts = admin.alerts()
    counts = {r["tax"]: r for r in ana.sql(
        "SELECT tax, count(*) FILTER (WHERE status = 'active') AS active, count(*) FILTER (WHERE status = 'draft') AS drafts "
        "FROM tax.rule GROUP BY tax")}
    taxes = ana.sql("SELECT code, name, scope, package FROM tax.tax WHERE active ORDER BY sequence, code")
    cases = ana.sql_value("SELECT count(*) FROM tax.test_case WHERE active")
    ana.metrics([{"label": "Tributos", "value": len(taxes)},
                 {"label": "Regras ativas", "value": sum(c["active"] for c in counts.values())},
                 {"label": "Casos de teste", "value": cases, "status": "ok" if cases else "warn",
                  "hint": "cada mudança roda os casos antes de valer"},
                 {"label": "Avisos", "value": len(alerts), "status": "bad" if alerts else "ok",
                  "hint": "nada pendente" if not alerts else "veja abaixo o que fazer"}], title="Impostos")
    if alerts:
        ana.table([{"aviso": a["text"], "gravidade": {"warning": "atenção", "serious": "grave"}.get(a["severity"], a["severity"]),
                    "_actions": [{"label": "Resolver", "program": a["action"]["program"], "params": a["action"]["params"],
                                  "open": True}] if a.get("action") else []} for a in alerts],
                  title="O que precisa de atenção")
    ana.table([{"tributo": t["name"], "código": t["code"], "escopo": "por item" if t["scope"] == "item" else "no documento",
                "regras ativas": counts.get(t["code"], {}).get("active", 0),
                "rascunhos": counts.get(t["code"], {}).get("drafts", 0), "pacote": t["package"] or "da empresa",
                "_actions": [{"label": "Regras", "program": "tax.rules", "params": {"tax": t["code"]}, "open": True}]}
               for t in taxes], title="Tributos cadastrados",
              empty="Nenhum tributo cadastrado.", empty_action={"label": "Aplicar um pacote de regras", "program": "tax.apply_package"})
    if not taxes:
        ana.actions([{"label": "Aplicar um pacote de regras para começar", "program": "tax.apply_package", "open": True}],
                    title="Nenhum tributo cadastrado")
    ana.actions([{"label": "Simular um documento", "program": "tax.simulate", "open": True},
                 {"label": "Qual regra vale?", "program": "tax.which_rule", "open": True},
                 {"label": "Casos de teste", "program": "tax.run_cases", "open": True},
                 {"label": "Aplicar pacote de regras", "program": "tax.apply_package", "open": True}],
                title="Próximos passos")
    return {"alerts": alerts, "taxes": len(taxes), "cases": cases}
