# ana:description Ajuste inicial do estoque: alinha a conta de estoque (e de produtos em elaboração) ao valor calculado, uma única vez
# ana:exposed yes
# ana:role admin
# ana:category Contabilidade/Lançamentos e fechamento
"""Spec 038 (RNF-038-03). Movements made before the valuation got their cost without retroactive
entries; this posts, once, the difference between the computed value and the ledger
(D/C inventory and work in process × opening balances). Preview first; confirm=True posts."""

from decimal import Decimal

from ana_lib.util import validation as v

DOC = "AJUSTE-ESTOQUE-INICIAL"
PARAMS = {"confirm": {"type": "bool", "default": False, "label": "lançar o ajuste"}}


def main(confirm=False):
    done = ana.sql_value("SELECT id FROM finance.journal_entry WHERE document = $1", DOC)
    v.require(not done, "ALREADY_DONE", f"o ajuste inicial já foi lançado (lançamento {done})")
    rows = {r["key"]: r for r in ana.sql(
        "SELECT key, account, difference FROM finance.reconciliation() WHERE key IN ('inventory', 'work_in_process')")}
    lines = []
    for k in ("inventory", "work_in_process"):
        d = Decimal(rows[k]["difference"] or 0)
        if d > 0:
            lines += [(rows[k]["account"], d, 0), ("@opening_balances", 0, d)]
        elif d < 0:
            lines += [("@opening_balances", -d, 0), (rows[k]["account"], 0, -d)]
    ana.table([{"conta": rows[k]["account"], "o que é": "Estoque" if k == "inventory" else "Produtos em elaboração",
                "diferença a lançar": rows[k]["difference"]} for k in ("inventory", "work_in_process")],
              title="Ajuste inicial (contrapartida: saldos de abertura)")
    if not lines:
        return {"posted": False, "reason": "nada a ajustar"}
    if not confirm:
        ana.actions([{"label": "Lançar o ajuste inicial", "program": "finance.inventory_opening_adjustment", "style": "primary",
                      "params": {"confirm": True}, "confirm": "Lançar o ajuste inicial do estoque? Só pode ser feito uma vez."}],
                    title="Próximo passo")
        return {"posted": False, "preview": True}
    entry = ana.sql_value("INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
                          "Ajuste inicial do estoque (valorização, spec 038)", DOC, ana.context.user)
    ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit) VALUES ($1, "
                  "CASE WHEN left($2, 1) = '@' THEN finance.account_for(substr($2, 2)) ELSE $2 END, $3, $4)",
                  [[entry, a, d, c] for a, d, c in lines])
    return {"posted": True, "entry": entry}
