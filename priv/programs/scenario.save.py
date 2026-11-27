# ana:description Cenários: guarda um cenário (nome e choques) para projetar, combinar e comparar depois
# ana:exposed yes
# ana:category Financeiro/Cenários
"""Spec 069 (T-069-03, RF-069-02, D2, D4). Saving is the only write of a scenario: one row with its shocks, checked
against the catalog (scenario.shocks.validate). Simulating never writes. Only the owner changes a scenario; a shared
one is seen (and combined) by others."""

import json

from ana_lib.scenario import shocks as sh

PARAMS = {
    "id": {"type": "int", "label": "cenário (vazio = novo)"},
    "name": {"type": "str", "required": True, "label": "nome"},
    "description": {"type": "text", "label": "descrição"},
    "shocks": {"type": "list", "label": "choques [{kind, params}]"},
    "shared": {"type": "bool", "default": False, "label": "outras pessoas podem ver e combinar"},
}


def main(name, id=None, description=None, shocks=None, shared=False):
    name = (name or "").strip()
    if not 3 <= len(name) <= 120:
        raise ana.Error("SCENARIO_NAME", "o nome do cenário tem de 3 a 120 caracteres")
    checked = sh.validate(shocks or [])
    stored = json.dumps([{"kind": s["kind"], "params": s["params"]} for s in checked], ensure_ascii=False)
    same = ana.sql_value("SELECT id FROM scenario.scenario WHERE owner = $1 AND name = $2", ana.context.user, name)
    if same is not None and same != id:
        raise ana.Error("SCENARIO_NAME", f"você já tem um cenário chamado {name!r}")
    if id is None:
        row = ana.sql_one("INSERT INTO scenario.scenario (name, description, owner, shocks, shared) "
                          "VALUES ($1, $2, $3, $4::jsonb, $5) RETURNING id, version",
                          name, description or "", ana.context.user, stored, bool(shared))
    else:
        row = ana.sql_one("UPDATE scenario.scenario SET name = $2, description = COALESCE($3, description), shocks = $4::jsonb, "
                          "  shared = $5, version = version + 1, updated_at = now() WHERE id = $1 AND owner = $6 "
                          "RETURNING id, version", id, name, description, stored, bool(shared), ana.context.user)
        if not row:
            raise ana.Error("SCENARIO_NOT_FOUND", "cenário não encontrado entre os seus (só quem criou altera)")
    ana.table([{"choque": s["label"]} for s in checked], title=f"Cenário {name}", empty="Sem choques: igual à base",
              empty_good=True)
    return {"id": row["id"], "version": row["version"], "name": name, "shocks": checked, "shared": bool(shared)}
