# ana:description Cria ou atualiza item (mercadoria ou serviço) pelo código
# ana:exposed yes
# ana:command product
# ana:category Cadastros/Clientes, fornecedores e itens
"""Upsert of a product by code. kind: goods (stock-controlled) | service."""

from ana_lib.util import validation as v

PARAMS = {
    "code": {"type": "str", "required": True, "label": "código"},
    "description": {"type": "str", "required": True, "label": "descrição"},
    "price": {"type": "decimal", "required": True, "label": "preço"},
    "unit": {"type": "str", "default": "UN", "label": "unidade"},
    "kind": {"type": "str", "default": "goods", "label": "tipo", "choices": [["goods", "Mercadoria (controla estoque)"], ["service", "Serviço"]]},
    "item_group": {"type": "str", "label": "grupo de itens (vazio apaga; ausente mantém)"},
}


def main(code, description, price, unit="UN", kind="goods", item_group=None):
    code = code.strip().upper()
    v.require(price >= 0, "INVALID_VALUE", "preço não pode ser negativo")
    v.require(kind in ("goods", "service"), "INVALID_KIND", f"tipo inválido: {kind}")
    r = ana.sql_one(
        "INSERT INTO base.product (code, description, unit, price, kind, item_group) VALUES ($1, $2, $3, $4, $5, NULLIF(upper(btrim($6)), '')) "
        "ON CONFLICT (code) DO UPDATE SET description = EXCLUDED.description, "
        "  unit = EXCLUDED.unit, price = EXCLUDED.price, kind = EXCLUDED.kind, "
        "  item_group = CASE WHEN $6::text IS NULL THEN base.product.item_group ELSE EXCLUDED.item_group END "
        "RETURNING id, (xmax = 0) AS created", code, description, unit, price, kind, item_group)
    return {"id": r["id"], "code": code, "created": r["created"]}
