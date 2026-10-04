# ana:description Registra ou atualiza risco ou pendência do projeto
# ana:exposed yes
"""RF-021-08. Team members register; changing or closing: manager or the risk owner."""

from ana_lib.projects import access
from ana_lib.projects import views as V

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto", "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "id": {"type": "int"},
    "kind": {"type": "str", "label": "tipo", "choices": [["risk", "Risco"], ["issue", "Pendência"]]},
    "title": {"type": "str"},
    "probability": {"type": "int"},
    "impact": {"type": "int"},
    "owner": {"type": "str"},
    "action_plan": {"type": "str"},
    "due_date": {"type": "date"},
    "status": {"type": "str", "label": "situação", "choices": [["open", "Aberto"], ["mitigating", "Em tratamento"], ["closed", "Fechado"]]},
    "client_visible": {"type": "bool"},
}

FIELDS = ["kind", "title", "probability", "impact", "owner", "action_plan", "due_date", "status", "client_visible"]


def main(project, id=None, **f):
    p = access.project(project)
    V.require_view(p)
    for k in ("probability", "impact"):
        if f.get(k) is not None and not 1 <= f[k] <= 5:
            raise ana.Error("INVALID_PARAMETER", f"{k} deve ser de 1 a 5")
    if f.get("kind") not in (None, "risk", "issue") or f.get("status") not in (None, "open", "mitigating", "closed"):
        raise ana.Error("INVALID_PARAMETER", "tipo ou situação inválidos")
    if id is None:
        if not f.get("title"):
            raise ana.Error("INVALID_PARAMETER", "informe o título")
        new_id = ana.sql_value(
            "INSERT INTO projects.risk (project_id, kind, title, probability, impact, owner, action_plan, due_date, "
            "  status, client_visible, created_by) VALUES ($1, COALESCE($2, 'risk'), $3, COALESCE($4::smallint, 3), "
            "  COALESCE($5::smallint, 3), $6, COALESCE($7, ''), $8, COALESCE($9, 'open'), COALESCE($10::boolean, false), "
            "  $11) RETURNING id", p["id"], *[f.get(k) for k in FIELDS], ana.context.user)
        return {"id": new_id}
    r = ana.sql_one("SELECT * FROM projects.risk WHERE id = $1 AND project_id = $2 FOR UPDATE", id, p["id"])
    if not r:
        raise ana.Error("RISK_NOT_FOUND", f"risco {id} não encontrado")
    if not (access.can_manage(p) or r["owner"] == ana.context.user or r["created_by"] == ana.context.user):
        raise ana.Error("FORBIDDEN", "só o gestor, o dono ou quem registrou")
    sets = [f"{k} = COALESCE(${n + 2}, {k})" for n, k in enumerate(FIELDS)]
    ana.sql_exec(f"UPDATE projects.risk SET {', '.join(sets)} WHERE id = $1", id, *[f.get(k) for k in FIELDS])
    return {"id": id}
