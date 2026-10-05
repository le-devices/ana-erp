# ana:description Catálogo de fornecimento: quem fornece cada item, preço, prazo e lote
# ana:exposed yes
# ana:command fornecimento
"""RF-013-01. One row per supplier and item; only one preferred supplier per item."""

from decimal import Decimal

from ana_lib.supply import common

PARAMS = {
    "product": {"type": "str", "required": True, "label": "item", "lookup": {"program": "supply.lookup", "params": {"kind": "products"}}},
    "supplier": {"type": "int", "required": True, "label": "fornecedor", "lookup": {"program": "supply.lookup", "params": {"kind": "suppliers"}}},
    "price": {"type": "decimal", "required": True, "label": "preço unitário"},
    "lead_time_days": {"type": "int", "default": 0, "label": "prazo de entrega (dias)"},
    "min_qty": {"type": "decimal", "default": 0, "label": "lote mínimo"},
    "multiple": {"type": "decimal", "default": 0, "label": "múltiplo de compra"},
    "preferred": {"type": "bool", "default": False, "label": "fornecedor preferencial"},
    "supplier_code": {"type": "str", "label": "código no fornecedor"},
    "currency": {"type": "str", "default": "BRL", "label": "moeda", "choices": [["BRL", "Real"], ["USD", "Dólar"], ["EUR", "Euro"]]},
    "valid_until": {"type": "date", "label": "preço válido até"},
}


def main(product, supplier, price, lead_time_days=0, min_qty=0, multiple=0, preferred=False,
         supplier_code=None, currency="BRL", valid_until=None):
    p = common.products([product])[str(product).upper()]
    s = common.supplier(supplier)
    if Decimal(price) < 0 or lead_time_days < 0 or Decimal(min_qty) < 0 or Decimal(multiple) < 0:
        raise ana.Error("INVALID_VALUE", "preço, prazo, lote e múltiplo não podem ser negativos")
    if preferred:
        ana.sql_exec("UPDATE supply.supplier_item SET preferred = false WHERE product_id = $1 AND supplier_id <> $2 "
                     "AND preferred", p["id"], s["id"])
    row = ana.sql_one(
        "INSERT INTO supply.supplier_item (supplier_id, product_id, supplier_code, price, currency, lead_time_days, "
        "  min_qty, multiple, preferred, valid_until) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) "
        "ON CONFLICT (supplier_id, product_id) DO UPDATE SET supplier_code = EXCLUDED.supplier_code, "
        "  price = EXCLUDED.price, currency = EXCLUDED.currency, lead_time_days = EXCLUDED.lead_time_days, "
        "  min_qty = EXCLUDED.min_qty, multiple = EXCLUDED.multiple, preferred = EXCLUDED.preferred, "
        "  valid_until = EXCLUDED.valid_until RETURNING id, (xmax = 0) AS created",
        s["id"], p["id"], supplier_code, price, currency.upper(), lead_time_days, min_qty, multiple, preferred, valid_until)
    rows = ana.sql("SELECT pa.name AS fornecedor, si.supplier_code AS \"código\", si.price AS \"preço\", si.currency AS moeda, "
                   "  si.lead_time_days AS \"prazo (dias)\", si.min_qty AS \"lote mín.\", si.multiple AS \"múltiplo\", "
                   "  CASE WHEN si.preferred THEN 'sim' ELSE '' END AS preferencial, si.valid_until AS \"válido até\" "
                   "FROM supply.supplier_item si JOIN base.party pa ON pa.id = si.supplier_id "
                   "WHERE si.product_id = $1 ORDER BY si.preferred DESC, si.price", p["id"])
    ana.table(rows, title=f"Fornecedores de {p['code']} — {p['description']}")
    return {"id": row["id"], "created": row["created"], "product": p["code"], "supplier": s["name"]}
