# ana:description Agenda técnico para a OS numa janela (sem sobreposição, respeitando ausências)
# ana:exposed yes
"""RF-015-06, CA-015-03. The database refuses two overlapping windows for the same technician
(exclusion constraint) and windows on days of absence."""

import datetime

from ana_lib.field import common

PARAMS = {
    "order": {"type": "int", "required": True, "label": "OS", "lookup": {"program": "logistics.lookup", "params": {"kind": "service_orders"}}},
    "technician": {"type": "int", "required": True, "label": "técnico", "lookup": {"program": "logistics.lookup", "params": {"kind": "technicians"}}},
    "start": {"type": "str", "required": True, "label": "início (AAAA-MM-DD HH:MM)"},
    "hours": {"type": "decimal", "default": 2, "label": "duração (h)"},
    "travel_min": {"type": "int", "default": 0, "label": "deslocamento estimado (min)"},
    "distance_km": {"type": "decimal", "label": "distância (km)"},
}


def main(order, technician, start, hours=2, travel_min=0, distance_km=None):
    o = common.order(order, lock=True)
    common.require_open(o)
    t = common.technician(technician)
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
    return {"assignment": aid, "order": o["number"], "technician": t["name"], "start": begin, "end": end}
