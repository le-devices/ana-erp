# ana:description Transportadora e tabela de frete por região e peso
# ana:exposed yes
"""RF-015-03. rates: [{"region": "SP" | "*", "max_weight_kg": 30, "price": 45}] (replaces the table)."""

PARAMS = {
    "name": {"type": "str", "required": True, "label": "nome"},
    "tracking_url": {"type": "str", "label": "endereço de rastreio (use {codigo})"},
    "rates": {"type": "list", "label": "tabela de frete"},
    "active": {"type": "bool", "default": True, "label": "ativa"},
}


def main(name, tracking_url=None, rates=None, active=True):
    cid = ana.sql_value("INSERT INTO logistics.carrier (name, tracking_url, active) VALUES ($1, $2, $3) "
                        "ON CONFLICT (name) DO UPDATE SET tracking_url = EXCLUDED.tracking_url, active = EXCLUDED.active RETURNING id",
                        name.strip(), tracking_url, active)
    if rates is not None:
        ana.sql_exec("DELETE FROM logistics.freight_rate WHERE carrier_id = $1", cid)
        ana.sql_batch("INSERT INTO logistics.freight_rate (carrier_id, region, max_weight_kg, price) VALUES ($1, $2, $3, $4)",
                      [[cid, str(r.get("region") or "*").upper(), r["max_weight_kg"], r["price"]] for r in rates])
    return {"id": cid}
