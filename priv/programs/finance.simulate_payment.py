# ana:description Simula uma condição de pagamento: parcelas, vencimentos e valor líquido
# ana:exposed yes
# ana:category Financeiro/Contas a receber e a pagar
"""RF-031-02. Shows installments, due dates, the adjusted total and what is left after the
operator's fee (cards)."""

import datetime
from decimal import Decimal

from ana_lib.finance import terms

PARAMS = {
    "term": {"type": "str", "required": True, "label": "condição", "lookup": {"program": "finance.lookup", "params": {"kind": "payment_terms"}}},
    "amount": {"type": "decimal", "required": True, "label": "valor"},
    "issue_date": {"type": "date", "label": "emissão (vazio = hoje)"},
}


def main(term, amount, issue_date=None):
    t = terms.get_term(term)
    total = terms.adjusted(amount, t)
    rows = terms.schedule(total, t, issue_date or datetime.date.today())
    fee = (total * Decimal(t["fee_pct"]) / 100).quantize(Decimal("0.01"))
    ana.metrics([{"label": "Total", "value": f"R$ {total}"}, {"label": "Parcelas", "value": len(rows)},
                 {"label": "Taxa da operadora", "value": f"R$ {fee}"}, {"label": "Líquido", "value": f"R$ {total - fee}"}],
                title=t["name"])
    ana.table([{"parcela": f"{n}/{len(rows)}", "vencimento": d, "valor": v} for n, d, v in rows], title="Parcelas")
    return {"total": total, "net": total - fee, "installments": [{"n": n, "due": d, "amount": v} for n, d, v in rows]}
