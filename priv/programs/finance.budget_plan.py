# ana:description Orçamento em grade: centro de custo × conta por mês, com orçado × realizado × saldo
# ana:role admin
# ana:category Contabilidade/Custos e orçamento
"""Spec 027 (RF-027-05) with the planning grid of spec 020 (RF-020-15/16, CA-020-10/11): the months come
from the chosen interval; cells are edited in place (or pasted from a spreadsheet) and only what changed is
saved (finance.save_budget_plan), refused when someone else saved the same scope in between."""

import datetime

from ana_lib.finance import budget

PARAMS = {
    "start": {"type": "str", "label": "de (mês, AAAA-MM)", "order": 1},
    "end": {"type": "str", "label": "até (mês, AAAA-MM)", "order": 2},
    "cost_center": {"type": "str", "label": "centro de custo (vazio = todos; inclui os filhos)", "order": 3,
                    "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}},
    "account": {"type": "str", "label": "conta (vazio = todas; prefixo vale)", "order": 4},
}


def main(start=None, end=None, cost_center=None, account=None):
    today = datetime.date.today()
    months = budget.months(start or f"{today.year}-01", end or f"{today.year}-12")
    scope = budget.scope(months, cost_center, account)
    rows = budget.rows(scope)
    ana.grid(rows, title="Orçamento por centro de custo e conta",
             dimensions=[{"key": "cost_center", "label": "Centro de custo"}, {"key": "account", "label": "Conta"}],
             periods=[{"key": m.isoformat()[:7], "label": budget.label(m)} for m in months],
             value_label="Orçado", consumed_label="Realizado", available_label="Saldo", unit="R$",
             statuses=budget.STATUSES, comments=True, version=budget.version(scope),
             add={"cost_center": {"program": "finance.lookup", "params": {"kind": "cost_centers"}},
                  "account": {"program": "finance.lookup", "params": {"kind": "accounts"}}},
             save={"program": "finance.save_budget_plan",
                   "params": {"start": months[0].isoformat()[:7], "end": months[-1].isoformat()[:7],
                              "cost_center": cost_center, "account": account}})
    return {"rows": len(rows), "months": len(months), "version": budget.version(scope)}
