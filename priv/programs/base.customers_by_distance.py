# ana:description Clientes por distância a partir da empresa ou de um depósito (e quem ainda não tem coordenadas)
# ana:command clientes_distancia
# ana:category Cadastros/Distâncias
"""RF-032-03. One set-based query (distance computed in the database)."""

from ana_lib.base import geo

PARAMS = {
    "origin": {"type": "str", "default": "EMPRESA", "label": "saindo de", "order": 1,
               "lookup": {"program": "sales.lookup", "params": {"kind": "origins"}}},
    "max_km": {"type": "decimal", "label": "até (km rodoviários; vazio = todos)", "order": 2},
}


def main(origin="EMPRESA", max_km=None):
    label, lat, lon = geo.origin(origin)
    rows = ana.sql(
        "SELECT id, name, city, state, base.distance_km($1, $2, latitude, longitude) AS straight, "
        "  base.road_km($1, $2, latitude, longitude) AS road "
        "FROM base.party WHERE active AND kind IN ('customer', 'both') AND latitude IS NOT NULL "
        "  AND ($3::numeric IS NULL OR base.road_km($1, $2, latitude, longitude) <= $3) "
        "ORDER BY road, name LIMIT 2000", lat, lon, max_km)
    missing = ana.sql_value("SELECT count(*) FROM base.party WHERE active AND kind IN ('customer', 'both') AND latitude IS NULL")
    # Spec 042 (E-04): how many there are, not how many fit the list.
    total = ana.sql_value("SELECT count(*) FROM base.party WHERE active AND kind IN ('customer', 'both') AND latitude IS NOT NULL "
                          "AND ($3::numeric IS NULL OR base.road_km($1, $2, latitude, longitude) <= $3)", lat, lon, max_km)
    ana.metrics([{"label": "Clientes no raio" if max_km else "Clientes com coordenadas", "value": total},
                 {"label": "Sem coordenadas", "value": missing, "status": "warn" if missing else "ok"}],
                title=f"Saindo de {label}")
    ana.table([{"cliente": f"{r['id']} — {r['name']}", "cidade": f"{r['city'] or ''}/{r['state'] or ''}",
                "reta (km)": r["straight"], "rodoviária (km)": r["road"],
                "_actions": [{"label": "Distância", "program": "base.distance", "params": {"customer": r["id"], "origin": origin},
                              "open": True}]} for r in rows],
              title="Clientes por distância" + (f" (os 2000 mais próximos de {total})" if total > len(rows) else ""))
    if missing:
        ana.actions([{"label": "Buscar coordenadas pelo endereço", "program": "base.geocode", "params": {"missing": True},
                      "confirm": "Consultar o serviço de geocodificação para os clientes sem coordenadas?"}],
                    title="Clientes sem coordenadas")
    return {"origin": label, "customers": total, "missing": missing}
