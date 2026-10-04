# ana:description Painel de vendas a partir da camada analítica
# ana:command dashboard
"""Reads the materialized views (spec 007): no contention with transactions."""

from ana_lib.util.format import money

PARAMS = {"days": {"type": "int", "default": 30}}


def main(days=30):
    by_product = ana.sql(
        "SELECT p.code, p.description, sum(s.quantity) AS quantity, sum(s.amount) AS amount "
        "FROM analytics.daily_sales s JOIN base.product p ON p.id = s.product_id "
        "WHERE s.day >= current_date - $1::int "
        "GROUP BY p.code, p.description ORDER BY amount DESC", days)
    by_customer = ana.sql(
        "SELECT c.name, sum(s.amount) AS amount, sum(s.orders) AS orders "
        "FROM analytics.sales_by_customer s JOIN base.party c ON c.id = s.customer_id "
        "GROUP BY c.name ORDER BY amount DESC LIMIT 10")
    ana.table([{**r, "amount": money(r["amount"])} for r in by_product], title="Vendas por item")
    ana.table([{**r, "amount": money(r["amount"])} for r in by_customer], title="Principais clientes")
    total = sum((r["amount"] for r in by_product), start=0)
    return {"total": total, "products": len(by_product)}
