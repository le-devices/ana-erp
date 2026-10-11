# ana:description Coordenadas e distâncias: origem (empresa ou depósito), cliente, reta, rodoviária e tempo
# ana:kind library
"""Spec 032. Distances come from the database functions (base.distance_km, base.road_km,
base.travel_minutes) so every screen and report computes them the same way."""

COMPANY = "EMPRESA"


def origin(code):
    """(label, lat, lon) of the company (code EMPRESA or empty) or of a warehouse."""
    if not code or str(code).upper() == COMPANY:
        r = ana.sql_one("SELECT legal_name AS label, latitude, longitude FROM base.company ORDER BY id LIMIT 1")
        if not r or r["latitude"] is None:
            raise ana.Error("NO_COORDINATES", "a empresa não tem coordenadas (Administração → Empresa)")
        return r["label"], r["latitude"], r["longitude"]
    r = ana.sql_one("SELECT code || ' — ' || description AS label, latitude, longitude FROM inventory.warehouse WHERE code = $1",
                    str(code).upper())
    if not r:
        raise ana.Error("WAREHOUSE_NOT_FOUND", f"depósito {code} não encontrado")
    if r["latitude"] is None:
        raise ana.Error("NO_COORDINATES", f"o depósito {code} não tem coordenadas (inventory.save_warehouse)")
    return r["label"], r["latitude"], r["longitude"]


def between(lat1, lon1, lat2, lon2):
    """{"straight_km", "road_km", "minutes"} or None when a point is missing."""
    if None in (lat1, lon1, lat2, lon2):
        return None
    return ana.sql_one("SELECT base.distance_km($1, $2, $3, $4) AS straight_km, base.road_km($1, $2, $3, $4) AS road_km, "
                       "base.travel_minutes(base.road_km($1, $2, $3, $4)) AS minutes", lat1, lon1, lat2, lon2)
