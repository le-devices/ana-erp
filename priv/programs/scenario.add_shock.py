# ana:description Cenários: inclui um choque num cenário seu (câmbio, preço, atraso, prazo, volume, capacidade, imposto, valor)
# ana:exposed yes
# ana:category Financeiro/Cenários
"""Spec 069 (T-069-05, RF-069-02). The screen's forms send one shock: its kind and its fields (the union of the
catalog's parameters; each kind takes its own). Checked with the others of the scenario before saving (one write)."""

import json

from ana_lib.scenario import shocks as sh

FIELDS = ("currency", "pct", "from", "until", "supplier", "customer", "item", "group", "days", "side", "resource", "rule",
          "name", "value")
PARAMS = {
    "id": {"type": "int", "required": True, "label": "cenário"},
    "kind": {"type": "str", "required": True, "label": "choque"},
    "currency": {"type": "str", "label": "moeda"},
    "pct": {"type": "decimal", "label": "percentual"},
    "from": {"type": "date", "label": "a partir de"},
    "until": {"type": "date", "label": "até"},
    "supplier": {"type": "int", "label": "fornecedor"},
    "customer": {"type": "int", "label": "cliente"},
    "item": {"type": "str", "label": "item"},
    "group": {"type": "str", "label": "grupo de itens"},
    "days": {"type": "int", "label": "dias"},
    "side": {"type": "str", "label": "prazo"},
    "resource": {"type": "str", "label": "recurso"},
    "rule": {"type": "int", "label": "regra de imposto em rascunho"},
    "name": {"type": "str", "label": "valor da empresa"},
    "value": {"type": "str", "label": "novo conteúdo"},
}


def main(id, kind, **fields):
    row = ana.sql_one("SELECT shocks FROM scenario.scenario WHERE id = $1 AND owner = $2 FOR UPDATE", id, ana.context.user)
    if not row:
        raise ana.Error("SCENARIO_NOT_FOUND", "cenário não encontrado entre os seus (só quem criou altera)")
    current = json.loads(row["shocks"]) if isinstance(row["shocks"], str) else row["shocks"]
    params = {k: (v.isoformat() if hasattr(v, "isoformat") else str(v) if k == "pct" else v)
              for k, v in fields.items() if k in FIELDS and v not in (None, "")}
    checked = sh.validate(current + [{"kind": kind, "params": params}])
    ana.sql_exec("UPDATE scenario.scenario SET shocks = $2::jsonb, version = version + 1, updated_at = now() WHERE id = $1",
                 id, json.dumps([{"kind": s["kind"], "params": s["params"]} for s in checked], ensure_ascii=False))
    ana.log(f"choque incluído: {checked[-1]['label']}")
    return {"id": id, "shocks": checked}
