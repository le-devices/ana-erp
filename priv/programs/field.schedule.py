# ana:description Agenda técnico para a OS numa janela (sem sobreposição, respeitando ausências)
# ana:exposed yes
"""RF-015-06, CA-015-03. The database refuses two overlapping windows for the same technician
(exclusion constraint) and windows on days of absence."""

import datetime

from ana_lib.field import common

PARAMS = {
    "order": {"type": "int", "required": True, "label": "OS", "lookup": {"program": "logistics.lookup", "params": {"kind": "service_orders"}}},
    "technician": {"type": "int", "required": True, "label": "técnico", "lookup": {"program": "logistics.lookup", "params": {"kind": "technicians"}}},
    "start": {"type": "datetime", "required": True, "label": "início"},
    "hours": {"type": "decimal", "default": 2, "label": "duração (h)"},
    "travel_min": {"type": "int", "label": "deslocamento estimado (min; vazio = calcular)"},
    "distance_km": {"type": "decimal", "label": "distância (km; vazio = calcular pelas coordenadas)"},
}


def main(order, technician, start, hours=2, travel_min=None, distance_km=None):
    o = common.order(order, lock=True)
    common.require_open(o)
    t = common.technician(technician)
    if distance_km is None:
        # CA-032-02: from the technician's base (vehicle warehouse, else the company) to the service address
        # (the order's coordinates, else the customer's).
        d = ana.sql_one(
            "SELECT base.road_km(COALESCE(w.latitude, c.latitude), COALESCE(w.longitude, c.longitude), "
            "  COALESCE(so.latitude, p.latitude), COALESCE(so.longitude, p.longitude)) AS km "
            "FROM field.service_order so JOIN base.party p ON p.id = so.customer_id "
            "LEFT JOIN inventory.warehouse w ON w.id = $2 "
            "LEFT JOIN LATERAL (SELECT latitude, longitude FROM base.company ORDER BY id LIMIT 1) c ON true WHERE so.id = $1",
            o["id"], t["warehouse_id"])
        distance_km = d["km"] if d else None
    if travel_min is None:
        travel_min = ana.sql_value("SELECT base.travel_minutes($1)", distance_km) if distance_km is not None else 0
    begin = datetime.datetime.fromisoformat(str(start))
    if hours <= 0 or hours > 24:
        raise ana.Error("INVALID_VALUE", "duração entre 0 e 24 h")
    end = begin + datetime.timedelta(hours=float(hours))
    try:
        with ana.savepoint():
            aid = ana.sql_value("INSERT INTO field.assignment (order_id, employee_id, period, travel_min, distance_km, created_by) "
                                "VALUES ($1, $2, tstzrange($3::timestamptz, $4::timestamptz), $5, $6, $7) RETURNING id",
                                o["id"], t["id"], begin.isoformat(), end.isoformat(), travel_min, distance_km, ana.context.user)
    except ana.SqlError as e:
        if e.sqlstate == "23P01":
            clash = ana.sql_one("SELECT so.number, lower(a.period) AS b, upper(a.period) AS e FROM field.assignment a "
                                "JOIN field.service_order so ON so.id = a.order_id WHERE a.employee_id = $1 AND a.status <> 'cancelled' "
                                "AND a.period && tstzrange($2::timestamptz, $3::timestamptz) LIMIT 1", t["id"], begin.isoformat(), end.isoformat())
            raise ana.Error("SCHEDULE_CONFLICT", f"{t['name']} já está na OS {clash['number']} de {clash['b']:%d/%m %H:%M} "
                            f"a {clash['e']:%H:%M}" if clash else f"{t['name']} já tem outro compromisso nesse horário") from None
        raise
    common.advance(o, "scheduled")
    return {"assignment": aid, "order": o["number"], "technician": t["name"], "start": begin, "end": end,
            "distance_km": distance_km, "travel_min": travel_min}
