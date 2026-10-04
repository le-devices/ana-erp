# ana:description Viabilidade do projeto: faturamento, custo e lucro projetados (base, otimista, pessimista)
# ana:exposed yes
# ana:command viabilidade
"""RF-021-12..15. Works from the proposal on: corrects rates, allocation,
deadlines and expenses before the project starts with bad numbers.
Optional `rate_pct`/`hours_pct`/`cost_pct`/`delay_weeks` simulate a case on
the spot (shown next to base, optimistic and pessimistic). Manager or admin
only: it shows cost and profit (RNF-021-02)."""

from ana_lib.projects import access
from ana_lib.projects import views as V

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto"},
    "rate_pct": {"type": "decimal", "label": "simular: valor-hora (%)"},
    "hours_pct": {"type": "decimal", "label": "simular: horas (%)"},
    "cost_pct": {"type": "decimal", "label": "simular: custo (%)"},
    "delay_weeks": {"type": "int", "label": "simular: atraso (semanas)"},
}


def main(project, rate_pct=None, hours_pct=None, cost_pct=None, delay_weeks=None):
    p = access.project(project)
    access.require_manager(p)
    sim = {"rate_pct": rate_pct or 0, "hours_pct": hours_pct or 0, "cost_pct": cost_pct or 0,
           "delay_weeks": delay_weeks or 0}
    return V.viability(p, sim if any(sim.values()) else None)
