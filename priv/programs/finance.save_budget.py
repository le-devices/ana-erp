# ana:description Orçamento por centro de custo, conta e mês
# ana:exposed yes
# ana:role admin
# ana:category Contabilidade/Custos e orçamento
"""RF-027-05. months: list of "AAAA-MM" (or a single month); amount per month."""

import datetime

PARAMS = {
    "cost_center": {"type": "str", "required": True, "label": "centro de custo",
                    "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}},
    "account": {"type": "str", "required": True, "label": "conta",
                "lookup": {"program": "finance.lookup", "params": {"kind": "accounts"}}},
    "months": {"type": "list", "required": True, "label": "meses (ex.: [\"2026-10\", \"2026-11\"])"},
    "amount": {"type": "decimal", "required": True, "label": "valor por mês"},
}


def main(cost_center, account, months, amount):
    rows = []
    for m in months:
        try:
            day = datetime.date.fromisoformat(str(m)[:7] + "-01")
        except ValueError:
            raise ana.Error("INVALID_PARAMETER", f"mês inválido: {m} (use AAAA-MM)") from None
        rows.append([cost_center.upper(), account, day, amount])
    ana.sql_batch("INSERT INTO finance.cost_center_budget (cost_center, account, month, amount) VALUES ($1, $2, $3, $4) "
                  "ON CONFLICT (cost_center, account, month) DO UPDATE SET amount = EXCLUDED.amount", rows)
    return {"months": len(rows)}
