# ana:description Compensa créditos de clientes (devoluções, pagamentos a mais) e créditos com fornecedores com os títulos em aberto do mesmo parceiro
# ana:exposed yes
# ana:command compensar
# ana:category Financeiro/Contas a receber e a pagar
"""Spec 038 (RF-038-05, CA-038-07). Oldest first, one entry per pair, residual when partial. Without a party:
every party with credits and open bills (the scheduled routine)."""

from ana_lib.finance import banking

PARAMS = {"party": {"type": "int", "label": "parceiro (vazio = todos)", "lookup": {"program": "sales.lookup", "params": {"kind": "customers"}}}}


def main(party=None):
    if party:
        parties = [party]
    else:
        parties = [r["party_id"] for r in ana.sql(
            "SELECT DISTINCT c.party_id FROM finance.bill c WHERE c.status = 'open' AND c.account IN "
            "(finance.account_for('customer_credits'), finance.account_for('supplier_credits'), finance.account_for('supplier_advances')) "
            "AND EXISTS (SELECT 1 FROM finance.bill d WHERE d.party_id = c.party_id AND d.status = 'open' "
            "  AND d.account IN (finance.account_for('customers'), finance.account_for('suppliers'))) LIMIT 5000")]
    made = []
    for p in parties:
        made += [{**m, "party": p} for m in banking.offset(p, ana.context.user)]
    ana.table([{"parceiro": m["party"], "crédito": m["credit"], "título": m["debit"], "valor": m["amount"]} for m in made],
              title="Compensações feitas")
    return {"offsets": len(made), "total": sum((m["amount"] for m in made), 0)}
