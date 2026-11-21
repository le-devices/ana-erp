# ana:description Indicador: pedidos com falta (retidos, aguardando compra ou produção, aceitos sem estoque)
# ana:menu no
# ana:indicator 300
"""Spec 048 (D1, CA-048-01). Runs as the user, read-only, on a block of the home panel."""


def main():
    n = ana.sql_value("SELECT count(*) FROM sales.sales_order WHERE status = 'OPEN' AND fulfillment <> 'ok'")
    held = ana.sql_value("SELECT count(*) FROM sales.sales_order WHERE status = 'OPEN' AND fulfillment = 'held'")
    if not n:
        return {"value": 0, "status": "ok", "text": "Nenhum pedido esperando estoque"}
    return {"value": n, "status": "warning",
            "text": f"{held} retido(s) até o estoque chegar" if held else "Aguardando compra ou produção"}
