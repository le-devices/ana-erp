# ana:description Regras de impostos com vigência: filtre por tributo, situação e data
# ana:exposed yes
# ana:command regrasimposto
# ana:category Fiscal/Regras e pacotes
"""Rules list (spec 049, RF-049-02). An active rule never changes: "Nova vigência" copies it with a new date."""

import json

PARAMS = {
    "tax": {"type": "str", "label": "tributo", "lookup": {"program": "tax.lookup", "params": {"kind": "taxes"}}},
    "status": {"type": "str", "label": "situação", "default": "active",
               "choices": [["active", "Ativas"], ["draft", "Rascunhos"], ["retired", "Retiradas"], ["all", "Todas"]]},
    "on": {"type": "date", "label": "vigentes em"},
}
STATUS = {"active": "ativa", "draft": "rascunho", "retired": "retirada"}


def main(tax=None, status="active", on=None):
    rows = ana.sql(
        "SELECT r.id, r.tax, t.name AS tax_name, r.name, r.valid_from, r.valid_to, r.criteria, r.status, r.package, r.version "
        "FROM tax.rule r JOIN tax.tax t ON t.code = r.tax "
        "WHERE ($1::text IS NULL OR r.tax = $1) AND ($2 = 'all' OR r.status = $2) "
        "  AND ($3::date IS NULL OR (r.valid_from <= $3 AND (r.valid_to IS NULL OR r.valid_to >= $3))) "
        "ORDER BY t.sequence, r.tax, r.valid_from DESC, r.id", tax, status or "active", on)
    out = []
    for r in rows:
        crit = json.loads(r["criteria"]) if isinstance(r["criteria"], str) else r["criteria"]
        acts = [{"label": "Detalhar", "program": "tax.rule", "params": {"rule": r["id"]}, "open": True}]
        if r["status"] == "active":
            acts.append({"label": "Nova vigência", "program": "tax.copy_rule", "params": {"rule": r["id"]}, "open": True})
        if r["status"] == "draft":
            acts.append({"label": "Ativar", "program": "tax.activate_rule", "params": {"rule": r["id"]}, "open": True})
        out.append({"regra": r["id"], "tributo": r["tax_name"], "nome": r["name"], "de": r["valid_from"], "até": r["valid_to"],
                    "critérios": ", ".join(f"{k} = {v}" for k, v in crit.items()) or "geral",
                    "situação": STATUS.get(r["status"], r["status"]), "origem": r["package"] or "empresa", "_actions": acts})
    ana.table(out, title="Regras de impostos")
    ana.actions([{"label": "Nova regra", "program": "tax.save_rule", "open": True},
                 {"label": "Qual regra vale?", "program": "tax.which_rule", "open": True}],
                title="Nenhuma regra com esses filtros" if not out else None)
    return {"rules": len(out)}
