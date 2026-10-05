# ana:description Salva cenário de projeção do projeto (ou ajusta o otimista/pessimista deste projeto)
# ana:exposed yes
"""RF-021-14/14a. kind=optimistic|pessimistic overrides the company policy
for this project; custom scenarios are compared side by side."""

from ana_lib.projects import access

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto", "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "name": {"type": "str", "label": "nome"},
    "kind": {"type": "str", "default": "custom", "label": "tipo", "choices": [["custom", "Cenário próprio"], ["optimistic", "Otimista deste projeto"], ["pessimistic", "Pessimista deste projeto"]]},
    "rate_pct": {"type": "decimal", "default": 0, "label": "valor-hora (%)"},
    "hours_pct": {"type": "decimal", "default": 0, "label": "horas (%)"},
    "cost_pct": {"type": "decimal", "default": 0, "label": "custo (%)"},
    "delay_weeks": {"type": "int", "default": 0, "label": "atraso (semanas)"},
    "notes": {"type": "str", "default": "", "label": "observações"},
    "remove": {"type": "bool", "default": False, "label": "remover"},
}


def main(project, name=None, kind="custom", rate_pct=0, hours_pct=0, cost_pct=0, delay_weeks=0, notes="",
         remove=False):
    p = access.project(project)
    access.require_manager(p)
    if kind not in ("custom", "optimistic", "pessimistic"):
        raise ana.Error("INVALID_PARAMETER", "tipo de cenário inválido")
    name = (name or {"optimistic": "otimista", "pessimistic": "pessimista"}.get(kind) or "").strip()
    if not name:
        raise ana.Error("INVALID_PARAMETER", "informe o nome do cenário")
    if remove:
        n = ana.sql_exec("DELETE FROM projects.scenario WHERE project_id = $1 AND (name = $2 OR ($3 <> 'custom' "
                         "AND kind = $3))", p["id"], name, kind)
        return {"removed": n}
    for v, lo in ((rate_pct, -90), (hours_pct, -90), (cost_pct, -90)):
        if v is not None and not lo <= v <= 500:
            raise ana.Error("INVALID_PARAMETER", "variações entre -90% e 500%")
    if kind != "custom":
        ana.sql_exec("DELETE FROM projects.scenario WHERE project_id = $1 AND kind = $2", p["id"], kind)
    ana.sql_exec(
        "INSERT INTO projects.scenario (project_id, name, kind, rate_pct, hours_pct, cost_pct, delay_weeks, notes, "
        "  created_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) ON CONFLICT (project_id, name) DO UPDATE SET "
        "  kind = EXCLUDED.kind, rate_pct = EXCLUDED.rate_pct, hours_pct = EXCLUDED.hours_pct, "
        "  cost_pct = EXCLUDED.cost_pct, delay_weeks = EXCLUDED.delay_weeks, notes = EXCLUDED.notes",
        p["id"], name, kind, rate_pct or 0, hours_pct or 0, cost_pct or 0, delay_weeks or 0, notes, ana.context.user)
    return {"project": p["code"], "name": name, "kind": kind}
