# ana:description Indicador: solicitações de compra aguardando aprovação
# ana:menu no
# ana:indicator 300
"""Spec 048 (D1). Runs as the user, read-only, on a block of the home panel."""


def main():
    n = ana.sql_value("SELECT count(*) FROM supply.purchase_request WHERE status = 'submitted'")
    if not n:
        return {"value": 0, "status": "ok", "text": "Nada esperando aprovação"}
    late = ana.sql_value("SELECT count(*) FROM supply.purchase_request WHERE status = 'submitted' "
                         "AND need_date IS NOT NULL AND need_date <= current_date + 3")
    return {"value": n, "status": "warning",
            "text": f"{late} com necessidade em até 3 dias" if late else "Aguardando a alçada"}
