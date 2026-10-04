# ana:description Consulta saldo de estoque por item e depósito
# ana:exposed yes
# ana:command balance
"""Current balance (real time, from movements)."""

from ana_lib.util.format import quantity as fmt_qty

PARAMS = {
    "product": {"type": "str"},
    "warehouse": {"type": "str"},
}


def main(product=None, warehouse=None):
    rows = ana.sql(
        "SELECT p.code AS product, p.description, w.code AS warehouse, sum(m.quantity) AS balance "
        "FROM inventory.stock_movement m "
        "JOIN base.product p ON p.id = m.product_id "
        "JOIN inventory.warehouse w ON w.id = m.warehouse_id "
        "WHERE ($1::text IS NULL OR p.code = upper($1)) "
        "  AND ($2::text IS NULL OR w.code = upper($2)) "
        "GROUP BY p.code, p.description, w.code ORDER BY p.code, w.code",
        product, warehouse)
    ana.table([{**r, "balance": fmt_qty(r["balance"], 0)} for r in rows], title="Saldo de estoque")
    return rows
