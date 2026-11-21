# ana:description Previsão de demanda em grade: item por semana, com previsto × vendido × saldo
# ana:exposed yes
# ana:category Produção/Planejamento
"""Spec 014 (RF-014-04) with the planning grid of spec 020 (RF-020-15/16): weeks from the chosen start;
the sold quantity is what the sales orders of each week took (the same consumption the planning uses);
saved by production.save_forecast_plan (only what changed, refused if someone saved in between)."""

import datetime

from ana_lib.production import common

PARAMS = {
    "start": {"type": "date", "label": "a partir da semana de", "order": 1},
    "weeks": {"type": "int", "default": 12, "label": "semanas", "order": 2},
    "product": {"type": "str", "label": "item (vazio = todos com previsão ou venda; prefixo vale)", "order": 3},
}
MAX_WEEKS = 52


def main(start=None, weeks=12, product=None):
    first = common.monday(start or datetime.date.today())
    weeks = max(1, min(int(weeks or 12), MAX_WEEKS))
    days = [first + datetime.timedelta(weeks=i) for i in range(weeks)]
    last = days[-1] + datetime.timedelta(days=7)
    prefix = (product or "").strip().upper() or None
    planned = ana.sql("SELECT p.code, p.description, f.week, f.quantity FROM production.forecast f JOIN base.product p ON p.id = f.product_id "
                      "WHERE f.week >= $1 AND f.week < $2 AND ($3::text IS NULL OR p.code LIKE $3 || '%')", first, last, prefix)
    sold = ana.sql("SELECT p.code, p.description, date_trunc('week', o.order_date)::date AS week, sum(i.quantity) AS quantity "
                   "FROM sales.sales_order_item i JOIN sales.sales_order o ON o.id = i.order_id JOIN base.product p ON p.id = i.product_id "
                   "WHERE o.status <> 'CANCELLED' AND p.kind = 'goods' AND o.order_date >= $1 AND o.order_date < $2 "
                   "AND ($3::text IS NULL OR p.code LIKE $3 || '%') GROUP BY 1, 2, 3", first, last, prefix)
    rows = {}
    for kind, data in (("values", planned), ("consumed", sold)):
        for r in data:
            row = rows.setdefault(r["code"], {"key": {"product": r["code"]}, "labels": {"product": f"{r['code']} {r['description']}"},
                                              "values": {}, "consumed": {}})
            row[kind][r["week"].isoformat()] = r["quantity"]
    ana.grid(sorted(rows.values(), key=lambda r: r["key"]["product"])[:2000], title="Previsão de demanda por item e semana",
             dimensions=[{"key": "product", "label": "Item"}],
             periods=[{"key": d.isoformat(), "label": f"{d:%d/%m}"} for d in days],
             value_label="Previsto", consumed_label="Vendido", available_label="Saldo da previsão", decimals=3,
             version=version(first, last, prefix),
             add={"product": {"program": "production.lookup", "params": {"kind": "products"}}},
             save={"program": "production.save_forecast_plan", "params": {"start": first.isoformat(), "weeks": weeks, "product": product}})
    return {"items": len(rows), "weeks": weeks}


def version(first, last, prefix):
    return ana.sql_value("SELECT md5(COALESCE(string_agg(concat_ws(';', p.code, f.week, f.quantity), '|' ORDER BY p.code, f.week), '')) "
                         "FROM production.forecast f JOIN base.product p ON p.id = f.product_id "
                         "WHERE f.week >= $1 AND f.week < $2 AND ($3::text IS NULL OR p.code LIKE $3 || '%')", first, last, prefix)
