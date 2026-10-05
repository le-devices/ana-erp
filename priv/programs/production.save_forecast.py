# ana:description Previsão de demanda por item e semana (consumida pelos pedidos reais)
# ana:exposed yes
"""RF-014-04. weeks: [{"week": "2026-10-12", "quantity": 50}] (any day: the week's Monday is used)."""

import datetime

from ana_lib.production import common

PARAMS = {
    "product": {"type": "str", "required": True, "label": "item", "lookup": {"program": "production.lookup", "params": {"kind": "products"}}},
    "weeks": {"type": "list", "required": True, "label": "semanas e quantidades"},
}


def main(product, weeks):
    p = common.product(product)
    rows = []
    for w in weeks:
        d = datetime.date.fromisoformat(str(w["week"])[:10])
        rows.append([p["id"], common.monday(d), w.get("quantity") or 0])
    ana.sql_batch("INSERT INTO production.forecast (product_id, week, quantity) VALUES ($1, $2, $3) "
                  "ON CONFLICT (product_id, week) DO UPDATE SET quantity = EXCLUDED.quantity", rows)
    return {"product": p["code"], "weeks": len(rows)}
