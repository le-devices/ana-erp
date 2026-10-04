# ana:description Aprova o plano do projeto e congela uma nova linha de base
# ana:exposed yes
"""RF-021-06, CA-021-01, CA-021-10. Approving the first plan activates a proposal.
Baselines are immutable (database trigger) and versioned; they keep the
projected revenue, cost and profit. Below the minimum margin requires a
justification (LOW_MARGIN)."""

from ana_lib.projects import access
from ana_lib.projects import consulting as C
from ana_lib.projects import finance as F

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto", "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "reason": {"type": "str", "default": "", "label": "observação"},
    "low_margin_justification": {"type": "str", "label": "justificativa (margem abaixo da mínima)"},
}


def main(project, reason="", low_margin_justification=None):
    p = access.project(project, lock=True)
    access.require_manager(p)
    # RF-021-15: the policy is checked on the plan as it is now (proposal values), before freezing it.
    proposal = dict(p)
    res = C.create_baseline(p, reason or "")
    base = F.check_and_record(proposal, res["baseline"], low_margin_justification)
    return {**res, "projected_profit": base["profit"], "projected_margin_pct": base["margin_pct"]}


