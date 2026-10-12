# ana:description Cadastros: aprovação de campos sensíveis por cadastro e campos próprios da empresa (clientes e itens)
# ana:exposed yes
# ana:role admin
"""Spec 040 (RF-040-01, RF-040-08). Without parameters: shows the policy of each entity and the custom fields."""

import re

from ana_lib.master import core
from ana_lib.master import entities

PARAMS = {
    "entity": {"type": "str", "label": "cadastro"},
    "approval": {"type": "bool", "label": "exigir aprovação de campos sensíveis"},
    "field": {"type": "dict", "label": "campo próprio (name, label, type, required, choices, active)"},
}
TYPES = ("text", "int", "decimal", "bool", "date", "choice")


def main(entity=None, approval=None, field=None):
    if entity:
        core.entity(entity)
        if approval is not None:
            ana.sql_exec("INSERT INTO master.policy (entity, approval, updated_by) VALUES ($1, $2, $3) "
                         "ON CONFLICT (entity) DO UPDATE SET approval = EXCLUDED.approval, updated_by = EXCLUDED.updated_by, "
                         "updated_at = now()", entity, approval, ana.context.user)
        if field:
            save_field(entity, field)
    pol = {r["entity"]: r["approval"] for r in ana.sql("SELECT entity, approval FROM master.policy")}
    ana.table([{"cadastro": e["plural"], "campos sensíveis": ", ".join(f["label"] for f in e["fields"] if f.get("sensitive")) or "—",
                "aprovação": "exigida" if pol.get(n) else "não",
                "_actions": [{"label": "Desligar aprovação" if pol.get(n) else "Exigir aprovação", "program": "master.settings",
                              "params": {"entity": n, "approval": not pol.get(n)}}]}
               for n, e in entities.ENTITIES.items()], title="Aprovação de campos sensíveis (quatro olhos)")
    fields = ana.sql("SELECT entity, name, label, type, required, choices, active FROM master.custom_field ORDER BY entity, position, name")
    ana.table([{"cadastro": entities.ENTITIES[f["entity"]]["plural"], "campo": f["name"], "rótulo": f["label"], "tipo": f["type"],
                "obrigatório": "sim" if f["required"] else "", "ativo": "sim" if f["active"] else "não"} for f in fields],
              title="Campos próprios da empresa")
    return {"policies": pol, "custom_fields": len(fields)}


def save_field(entity, f):
    if not entities.ENTITIES[entity].get("custom"):
        raise ana.Error("INVALID_PARAMETER", "este cadastro não aceita campos próprios")
    name = str(f.get("name") or "").strip().lower()
    if not re.fullmatch(r"[a-z][a-z0-9_]{1,40}", name) or name in {x["name"] for x in entities.ENTITIES[entity]["fields"]}:
        raise ana.Error("INVALID_PARAMETER", "nome do campo: letras minúsculas, números e _; diferente dos campos do produto")
    if f.get("type", "text") not in TYPES:
        raise ana.Error("INVALID_PARAMETER", "tipo deve ser um de: " + ", ".join(TYPES))
    ana.sql_exec("INSERT INTO master.custom_field (entity, name, label, type, required, choices, active, created_by) "
                 "VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT (entity, name) DO UPDATE SET label = EXCLUDED.label, "
                 "type = EXCLUDED.type, required = EXCLUDED.required, choices = EXCLUDED.choices, active = EXCLUDED.active",
                 entity, name, str(f.get("label") or name).strip(), f.get("type", "text"), bool(f.get("required")),
                 [str(c) for c in (f.get("choices") or [])], f.get("active", True) is not False, ana.context.user)
