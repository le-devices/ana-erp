# ana:description Projeto: visão geral, estrutura, alocação, quadro, linha do tempo, andamento, mudanças, riscos
# ana:command proj
# ana:category Projetos/Planejamento
"""RF-021-10/11: everything about one client project in tabs of the same
screen, with the guided flow (current stage and next step)."""

from ana_lib.projects import access
from ana_lib.projects import views as V

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto", "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "view": {"type": "str", "default": "overview", "label": "aba", "choices": [["overview", "Visão geral"], ["viability", "Viabilidade"], ["structure", "Estrutura"], ["allocation", "Alocação"], ["board", "Quadro"], ["gantt", "Linha do tempo"], ["progress", "Andamento"], ["changes", "Mudanças"], ["risks", "Riscos"], ["billing", "Faturamento"], ["reports", "Relatórios"], ["activity", "Detalhe da atividade"]]},
    "activity": {"type": "str", "label": "atividade (aba Detalhe da atividade)", "lookup": {"program": "projects.lookup", "params": {"kind": "activities"}, "depends": ["project"]}},
    "weeks": {"type": "int", "default": 6, "label": "semanas (alocação)"},
}


def main(project, view="overview", activity=None, weeks=6):
    p = access.project(project)
    V.require_view(p)
    V.header(p, "structure" if view == "activity" else view)
    if view == "activity":
        if not activity:
            raise ana.Error("INVALID_PARAMETER", "informe a atividade")
        return {"project": p["code"], "view": view, "data": V.activity_detail(p, activity)}
    render = {"overview": V.overview, "viability": V.viability, "structure": V.structure, "board": V.board, "gantt": V.gantt,
              "progress": V.progress, "changes": V.changes, "risks": V.risks, "billing": V.billing,
              "reports": V.reports, "allocation": lambda p: V.allocation(p, max(1, min(weeks, 26)))}.get(view)
    if render is None:
        raise ana.Error("INVALID_PARAMETER", f"aba desconhecida: {view}")
    return {"project": p["code"], "view": view, "data": render(p)}
