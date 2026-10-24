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
}


def main(code, description, price, unit="UN", kind="goods"):
    code = code.strip().upper()
    v.require(price >= 0, "INVALID_VALUE", "preço não pode ser negativo")
    v.require(kind in ("goods", "service"), "INVALID_KIND", f"tipo inválido: {kind}")
    r = ana.sql_one(
        "INSERT INTO base.product (code, description, unit, price, kind) VALUES ($1, $2, $3, $4, $5) "
        "ON CONFLICT (code) DO UPDATE SET description = EXCLUDED.description, "
        "  unit = EXCLUDED.unit, price = EXCLUDED.price, kind = EXCLUDED.kind "
        "RETURNING id, (xmax = 0) AS created", code, description, unit, price, kind)
    return {"id": r["id"], "code": code, "created": r["created"]}
