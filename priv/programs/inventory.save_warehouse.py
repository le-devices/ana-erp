# ana:description Cria ou atualiza depósito (descrição, centro de custo e coordenadas)
# ana:exposed yes
"""Spec 032 (coordinates for distances) — the warehouse code is the key."""

from ana_lib.util import validation as v

PARAMS = {
    "code": {"type": "str", "required": True, "label": "código"},
    "description": {"type": "str", "required": True, "label": "descrição"},
    "cost_center": {"type": "str", "label": "centro de custo",
                    "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}},
    "latitude": {"type": "decimal", "label": "latitude (ex.: -23,5505)"},
    "longitude": {"type": "decimal", "label": "longitude (ex.: -46,6333)"},
}


def main(code, description, cost_center=None, latitude=None, longitude=None):
    code = code.strip().upper()
    v.require(1 <= len(code) <= 30, "INVALID_CODE", "código de 1 a 30 caracteres")
    lat, lon = v.coordinates(latitude, longitude)
    wid = ana.sql_value(
        "INSERT INTO inventory.warehouse (code, description, cost_center, latitude, longitude) VALUES ($1, $2, $3, $4, $5) "
        "ON CONFLICT (code) DO UPDATE SET description = EXCLUDED.description, "
        "  cost_center = COALESCE(EXCLUDED.cost_center, inventory.warehouse.cost_center), "
        "  latitude = EXCLUDED.latitude, longitude = EXCLUDED.longitude RETURNING id",
        code, description.strip(), cost_center.upper() if cost_center else None, lat, lon)
    return {"id": wid, "code": code}
