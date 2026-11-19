# ana:description Detalhe de uma regra de imposto: critérios, fórmulas, vigência e histórico
# ana:exposed yes
# ana:menu no
# ana:category Fiscal/Regras e pacotes
"""One rule with its formulas and history (spec 049)."""

from ana_lib.tax import admin

PARAMS = {"rule": {"type": "int", "required": True, "label": "regra"}}


def main(rule):
    r = admin.get_rule(rule)
    ana.table([{"campo": k, "valor": v} for k, v in (r["criteria"] or {}).items()] or [{"campo": "geral", "valor": "vale para todos"}],
              title=f"Regra {r['id']} — {r['name']} (critérios)")
    ana.table([{"fórmula": n, "expressão": e} for n, e in r["formulas"]], title="Fórmulas, na ordem")
    hist = ana.sql("SELECT at, username, kind, reason, cases_run FROM tax.change WHERE target = $1 ORDER BY at DESC",
                   f"rule:{r['id']}")
    ana.table([{"quando": h["at"], "quem": h["username"], "o quê": h["kind"], "motivo": h["reason"], "casos": h["cases_run"]}
               for h in hist] or [{"quando": "", "quem": "", "o quê": "sem ativações registradas", "motivo": "", "casos": ""}],
              title="Histórico")
    acts = []
    if r["status"] == "active":
        acts.append({"label": "Nova vigência a partir de uma data", "program": "tax.copy_rule", "params": {"rule": r["id"]}, "open": True})
    if r["status"] == "draft":
        acts += [{"label": "Editar", "program": "tax.save_rule", "params": {"rule": r["id"]}, "open": True},
                 {"label": "Ativar (roda os casos de teste)", "program": "tax.activate_rule", "params": {"rule": r["id"]}, "open": True}]
    if r["status"] != "retired":
        acts.append({"label": "Retirar", "program": "tax.retire_rule", "params": {"rule": r["id"]}, "open": True})
    ana.actions(acts, title="Próximos passos")
    return {k: v for k, v in r.items()}
