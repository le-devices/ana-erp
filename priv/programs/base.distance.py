# ana:description Distância aproximada da empresa (ou de um depósito) até um cliente: reta, rodoviária e tempo
# ana:command distancia
# ana:category Cadastros/Distâncias
"""RF-032-02, CA-032-01. Straight line by the haversine formula; road ≈ straight × factor
(base.geo_settings); time by average speed. Without external services."""

from ana_lib.base import geo
from ana_lib.util.format import compact

PARAMS = {
    "customer": {"type": "int", "required": True, "label": "cliente", "order": 1,
                 "lookup": {"program": "sales.lookup", "params": {"kind": "customers"}}},
    "origin": {"type": "str", "default": "EMPRESA", "label": "saindo de", "order": 2,
               "lookup": {"program": "sales.lookup", "params": {"kind": "origins"}}},
}


def main(customer, origin="EMPRESA"):
    label, lat, lon = geo.origin(origin)
    c = ana.sql_one("SELECT name, city, state, latitude, longitude FROM base.party WHERE id = $1", customer)
    if not c:
        raise ana.Error("CUSTOMER_NOT_FOUND", f"cliente {customer} não encontrado")
    d = geo.between(lat, lon, c["latitude"], c["longitude"])
    if not d:
        ana.actions([{"label": "Informar coordenadas", "program": "base.save_party", "params": {"id": customer, "_form": "1"}, "open": True},
                     {"label": "Buscar pelo endereço", "program": "base.geocode", "params": {"party": customer}}],
                    title=f"{c['name']} não tem coordenadas")
        return {"customer": customer, "distance": None}
    h, m = divmod(d["minutes"] or 0, 60)
    ana.metrics([{"label": "Em linha reta", "value": f"{compact(d['straight_km'])} km"},
                 {"label": "Rodoviária (aprox.)", "value": f"{compact(d['road_km'])} km"},
                 {"label": "Tempo estimado", "value": f"{h} h {m:02d} min" if h else f"{m} min"}],
                title=f"{label} → {c['name']}" + (f" ({c['city']}/{c['state']})" if c["city"] else ""))
    return {"customer": customer, "origin": label, **d}
