# ana:description Cenários: guarda um cenário (nome e choques) para projetar, combinar e comparar depois
# ana:exposed yes
# ana:category Financeiro/Cenários
"""Spec 069 (T-069-03, RF-069-02, D2, D4). Saving is the only write of a scenario: one row with its shocks, checked
against the catalog (scenario.shocks.validate) — with the owner's data scope: a shock never points to what they cannot
see. Simulating never writes. Only the owner changes a scenario; shared with a group (D8), its members see and combine
it, each one recalculating with their own scope."""

import json

from ana_lib.scenario import shocks as sh

PARAMS = {
    "id": {"type": "int", "label": "cenário (vazio = novo)"},
    "name": {"type": "str", "required": True, "label": "nome"},
    "description": {"type": "text", "label": "descrição"},
    "shocks": {"type": "list", "label": "choques [{kind, params}]"},
    "group": {"type": "str", "label": "compartilhar com o grupo (vazio = só você)"},
}

NEXT = [{"label": "Abrir na tela de cenários", "program": "scenario.workbench", "params": {"view": "compare", "scenarios": ["{{result.id}}"]}, "open": True, "style": "primary"},
        {"label": "Cenários", "program": "scenario.workbench", "params": {"view": "list"}, "open": True}]


def main(name, id=None, description=None, shocks=None, group=None):
    name = (name or "").strip()
    if not 3 <= len(name) <= 120:
        raise ana.Error("SCENARIO_NAME", "o nome do cenário tem de 3 a 120 caracteres")
    checked = sh.validate(shocks or [])
    group = (group or "").strip() or None
    if group and ana.context.role != "admin" and group not in {r["g"] for r in ana.sql(
            "SELECT g FROM bpm.user_groups($1) AS g", ana.context.user)}:
        raise ana.Error("SCENARIO_GROUP", f"você não está no grupo {group}: só compartilha com um grupo seu")
    stored = json.dumps([{"kind": s["kind"], "params": s["params"]} for s in checked], ensure_ascii=False)
    same = ana.sql_value("SELECT id FROM scenario.scenario WHERE owner = $1 AND name = $2", ana.context.user, name)
    if same is not None and same != id:
        raise ana.Error("SCENARIO_NAME", f"você já tem um cenário chamado {name!r}")
    if id is None:
        row = ana.sql_one("INSERT INTO scenario.scenario (name, description, owner, shocks, shared_group) "
                          "VALUES ($1, $2, $3, $4::jsonb, $5) RETURNING id, version",
                          name, description or "", ana.context.user, stored, group)
    else:
        row = ana.sql_one("UPDATE scenario.scenario SET name = $2, description = COALESCE($3, description), shocks = $4::jsonb, "
                          "  shared_group = $5, version = version + 1, updated_at = now() WHERE id = $1 AND owner = $6 "
                          "RETURNING id, version", id, name, description, stored, group, ana.context.user)
        if not row:
            raise ana.Error("SCENARIO_NOT_FOUND", "cenário não encontrado entre os seus (só quem criou altera)")
    ana.table([{"choque": s["label"]} for s in checked], title=f"Cenário {name}", empty="Sem choques: igual à base",
              empty_good=True)
    return {"id": row["id"], "version": row["version"], "name": name, "shocks": checked, "group": group}
