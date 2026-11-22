# ana:description Indicador: títulos a receber vencidos (quantidade e valor)
# ana:menu no
# ana:indicator 600
"""Spec 048 (D1). Runs as the user, read-only, on a block of the home panel."""

from ana_lib.util.format import money


def main():
    r = ana.sql_one("SELECT count(*) AS n, COALESCE(sum(amount), 0) AS total FROM finance.bill "
                    "WHERE kind = 'receivable' AND status = 'open' AND due_date < current_date")
    if not r["n"]:
        return {"value": 0, "status": "ok", "text": "Nenhum título a receber vencido"}
    old = ana.sql_value("SELECT count(*) FROM finance.bill WHERE kind = 'receivable' AND status = 'open' "
                        "AND due_date < current_date - 30")
    return {"value": r["n"], "status": "critical" if old else "warning",
            "text": f"{money(r['total'])} em atraso" + (f"; {old} há mais de 30 dias" if old else "")}
