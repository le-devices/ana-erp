# ana:description Rota do dia do técnico: paradas em ordem, horários estimados e distância
# ana:exposed yes
"""RF-015-07. Without order, the stops follow the scheduled time; `order` (assignment ids in the
desired sequence) reorders them manually and the estimated times are recomputed."""

import datetime

from ana_lib.field import common

PARAMS = {
    "technician": {"type": "int", "required": True, "label": "técnico", "lookup": {"program": "logistics.lookup", "params": {"kind": "technicians"}}},
    "day": {"type": "date", "label": "dia (vazio = hoje)"},
    "order": {"type": "list", "label": "nova ordem das paradas (ids)"},
}


def main(technician, day=None, order=None):
    t = common.technician(technician)
    day = day or datetime.date.today()
    if order:
        ana.sql_exec("UPDATE field.assignment a SET seq = x.n FROM unnest($2::bigint[]) WITH ORDINALITY AS x(id, n) "
                     "WHERE a.id = x.id AND a.employee_id = $1", t["id"], [int(i) for i in order])
    stops = ana.sql("SELECT a.id, a.seq, lower(a.period) AS b, upper(a.period) AS e, a.travel_min, a.distance_km, so.number, "
                    "  p.name AS customer, so.site_address FROM field.assignment a JOIN field.service_order so ON so.id = a.order_id "
                    "JOIN base.party p ON p.id = so.customer_id WHERE a.employee_id = $1 AND a.status <> 'cancelled' "
                    "AND a.period && tstzrange($2::date::timestamptz, ($2::date + 1)::timestamptz) ORDER BY a.seq NULLS LAST, lower(a.period)",
                    t["id"], day)
    out, clock, total_km = [], None, 0
    for n, s in enumerate(stops, start=1):
        arrive = s["b"] if clock is None else max(s["b"], clock + datetime.timedelta(minutes=s["travel_min"]))
        leave = arrive + (s["e"] - s["b"])
        clock = leave
        total_km += float(s["distance_km"] or 0)
        out.append({"parada": n, "OS": s["number"], "cliente": s["customer"], "endereço": s["site_address"],
                    "chegada estimada": f"{arrive:%H:%M}", "saída": f"{leave:%H:%M}", "deslocamento (min)": s["travel_min"],
                    "km": s["distance_km"], "id": s["id"]})
    ana.metrics([{"label": "Paradas", "value": len(out)}, {"label": "Distância", "value": f"{total_km:.1f} km"},
                 {"label": "Fim previsto", "value": f"{clock:%H:%M}" if clock else "—"}], title=f"Rota de {t['name']} em {day:%d/%m/%Y}")
    ana.table(out, title="Paradas")
    return {"stops": out, "km": total_km}
