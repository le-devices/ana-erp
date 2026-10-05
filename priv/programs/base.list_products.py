# ana:description Lista mercadorias e serviços (com saldo só para mercadorias)
# ana:exposed yes
# ana:command products
"""Item listing (RF-006-09). Items without movements show balance 0;
services never have a stock balance."""

from ana_lib.util.format import money, quantity

PARAMS = {
    "kind": {"type": "str", "label": "tipo", "choices": [["goods", "Mercadorias"], ["service", "Serviços"]]},
    "search": {"type": "str", "label": "buscar"},
    "include_inactive": {"type": "bool", "default": False, "label": "incluir inativos"},
}


def main(kind=None, search=None, include_inactive=False):
    if kind not in (None, "", "goods", "service"):
        raise ana.Error("INVALID_KIND", "tipo deve ser goods ou service")
    # ana:lint-ok leading_wildcard — substring search backed by trigram indexes (migration 020)
    rows = ana.sql(
        "SELECT p.code, p.description, p.kind, p.unit, p.price, p.active, "
        "       CASE WHEN p.kind = 'goods' THEN COALESCE(s.balance, 0) END AS balance "
        "FROM base.product p "
        "LEFT JOIN LATERAL (SELECT sum(m.quantity) AS balance FROM inventory.stock_movement m "
        "                   WHERE m.product_id = p.id AND p.kind = 'goods') s ON true "
        "WHERE ($1::text IS NULL OR $1 = '' OR p.kind = $1) "
        "  AND ($2::text IS NULL OR p.code ILIKE '%' || $2 || '%' OR p.description ILIKE '%' || $2 || '%') "
        "  AND (p.active OR $3) "
        "ORDER BY p.kind, p.code LIMIT 1000", kind, search, include_inactive)
    ana.table([{"código": r["code"], "descrição": r["description"],
                "tipo": "serviço" if r["kind"] == "service" else "mercadoria",
                "unidade": r["unit"], "preço": money(r["price"]),
                "saldo": "—" if r["balance"] is None else quantity(r["balance"], 0),
                "situação": "ativo" if r["active"] else "inativo"} for r in rows],
              title="Itens")
    return rows
