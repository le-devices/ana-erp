# ana:description Transportadora e tabela de frete por região e peso
# ana:exposed yes
"""RF-015-03. rates: [{"region": "SP" | "*", "max_weight_kg": 30, "price": 45}] (replaces the table).
Spec 038: every carrier is also a supplier party (found by tax id or name, else created), so the
freight of each shipment becomes a payable bill without any manual registration."""

PARAMS = {
    "name": {"type": "str", "required": True, "label": "nome"},
    "tax_id": {"type": "str", "label": "CNPJ (liga ao fornecedor)"},
    "tracking_url": {"type": "str", "label": "endereço de rastreio (use {codigo})"},
    "rates": {"type": "list", "label": "tabela de frete", "add_label": "Adicionar faixa", "columns": {
        "region": {"type": "str", "default": "*", "label": "UF de destino (* = demais)"},
        "max_weight_kg": {"type": "decimal", "required": True, "label": "até (kg)"},
        "max_km": {"type": "decimal", "label": "até (km; vazio = qualquer)"},
        "price": {"type": "decimal", "required": True, "label": "preço"}}},
    "active": {"type": "bool", "default": True, "label": "ativa"},
    "default": {"type": "bool", "default": False, "label": "transportadora padrão (expedição sem escolha, esteira automática)"},
}


def main(name, tracking_url=None, rates=None, active=True, default=False, tax_id=None):
    name = name.strip()
    tax_id = (tax_id or "").strip() or None
    party = ana.sql_value("SELECT party_id FROM logistics.carrier WHERE name = $1", name) or ana.sql_value(
        "SELECT id FROM base.party WHERE ($1::text IS NOT NULL AND tax_id = $1) OR (tax_id IS NOT DISTINCT FROM $1 AND name = $2 "
        "AND kind IN ('supplier', 'both')) ORDER BY (tax_id IS NOT NULL) DESC, id LIMIT 1", tax_id, name)
    if party:
        ana.sql_exec("UPDATE base.party SET kind = 'both' WHERE id = $1 AND kind = 'customer'", party)
    else:
        party = ana.sql_value("INSERT INTO base.party (kind, name, tax_id) VALUES ('supplier', $1, $2) RETURNING id", name, tax_id)
    cid = ana.sql_value("INSERT INTO logistics.carrier (name, tracking_url, active, party_id) VALUES ($1, $2, $3, $4) "
                        "ON CONFLICT (name) DO UPDATE SET tracking_url = EXCLUDED.tracking_url, active = EXCLUDED.active, "
                        "  party_id = COALESCE(logistics.carrier.party_id, EXCLUDED.party_id) RETURNING id",
                        name, tracking_url, active, party)
    if rates is not None:
        ana.sql_exec("DELETE FROM logistics.freight_rate WHERE carrier_id = $1", cid)
        ana.sql_batch("INSERT INTO logistics.freight_rate (carrier_id, region, max_weight_kg, price, max_km) VALUES ($1, $2, $3, $4, $5)",
                      [[cid, str(r.get("region") or "*").upper(), r["max_weight_kg"], r["price"], r.get("max_km") or None] for r in rates])
    if default:
        ana.sql_exec("UPDATE logistics.policy SET default_carrier = $1 WHERE id = 1", cid)   # spec 030
    return {"id": cid, "default": bool(default)}
