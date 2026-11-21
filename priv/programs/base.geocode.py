# ana:description Busca coordenadas de clientes pelo endereço, pelo conector de geocodificação configurado
# ana:exposed yes
# ana:category Cadastros/Distâncias
"""RF-032-04. Uses the connector chosen in base.geo_settings (spec 017: allowed hosts,
credentials in the vault, limits). Contract: GET /search?q=<address>&format=json&limit=1
answering [{"lat", "lon"}] (or {"lat", "lon"}) — the common geocoders' format. Without a
connector nothing leaves the installation."""

from decimal import Decimal

PARAMS = {
    "party": {"type": "int", "label": "cliente (vazio = os sem coordenadas)",
              "lookup": {"program": "sales.lookup", "params": {"kind": "customers"}}},
    "missing": {"type": "bool", "default": False, "label": "todos os clientes sem coordenadas (até 50 por vez)"},
}


def main(party=None, missing=False):
    connector = ana.sql_value("SELECT geocoder_connector FROM base.geo_policy WHERE id = 1")
    if not connector:
        raise ana.Error("GEOCODER_NOT_CONFIGURED", "nenhum conector de geocodificação: escolha um em base.geo_settings "
                                                   "ou informe as coordenadas no cadastro")
    if party:
        rows = ana.sql("SELECT id, name, address, city, state FROM base.party WHERE id = $1", party)
    elif missing:
        rows = ana.sql("SELECT id, name, address, city, state FROM base.party WHERE active AND latitude IS NULL "
                       "AND kind IN ('customer', 'both') AND (address IS NOT NULL OR city IS NOT NULL) ORDER BY id LIMIT 50")
    else:
        raise ana.Error("INVALID_PARAMETER", "informe o cliente ou marque todos os sem coordenadas")
    found, not_found = [], []
    for r in rows:
        query = ", ".join(x for x in (r["address"], r["city"], r["state"], "Brasil") if x)
        # ana:lint-ok sql_in_loop — one external call and one update per customer (at most 50)
        resp = ana.http(connector, "GET", "/search", params={"q": query, "format": "json", "limit": "1"})
        body = resp.get("json") if isinstance(resp, dict) else None
        hit = body[0] if isinstance(body, list) and body else body if isinstance(body, dict) else None
        try:
            lat, lon = Decimal(str(hit["lat"])), Decimal(str(hit["lon"]))
        except (TypeError, KeyError, ArithmeticError, ValueError):
            not_found.append(r["name"])
            continue
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            not_found.append(r["name"])
            continue
        ana.sql_exec("UPDATE base.party SET latitude = $2, longitude = $3 WHERE id = $1", r["id"], round(lat, 6), round(lon, 6))
        found.append({"customer": r["name"], "latitude": round(lat, 6), "longitude": round(lon, 6)})
    if found:
        ana.table(found, title="Coordenadas encontradas")
    if not_found:
        ana.log(f"sem resultado: {', '.join(not_found)}", "warning")
    return {"found": len(found), "not_found": not_found}
