# ana:description Agenda da semana: técnicos × dias, conflitos e deslocamentos
# ana:command agenda
"""RF-015-06, RNF-015-03: one query for the whole week (100 technicians < 1 s)."""

import datetime

PARAMS = {"week": {"type": "date", "label": "semana de (vazio = esta)"}}
DAYS = ["seg", "ter", "qua", "qui", "sex", "sáb", "dom"]


def main(week=None):
    d = week or datetime.date.today()
    first = d - datetime.timedelta(days=d.weekday())
    last = first + datetime.timedelta(days=7)
    rows = ana.sql(
        "SELECT e.id, e.name, a.id AS aid, so.number, p.name AS customer, lower(a.period) AS b, upper(a.period) AS e, a.travel_min, so.priority "
        "FROM field.technician t JOIN projects.employee e ON e.id = t.employee_id "
        "LEFT JOIN field.assignment a ON a.employee_id = e.id AND a.status <> 'cancelled' "
        "  AND a.period && tstzrange($1::timestamptz, $2::timestamptz) "
        "LEFT JOIN field.service_order so ON so.id = a.order_id LEFT JOIN base.party p ON p.id = so.customer_id "
        "WHERE t.active ORDER BY e.name, lower(a.period)", first.isoformat(), last.isoformat())
    techs = {}
    for r in rows:
        tech = techs.setdefault(r["id"], {"técnico": r["name"], **{f"{DAYS[k]} {(first + datetime.timedelta(days=k)):%d/%m}": "" for k in range(7)}})
        if r["aid"]:
            day = r["b"].date() if hasattr(r["b"], "date") else r["b"]
            key = f"{DAYS[(day - first).days]} {day:%d/%m}" if 0 <= (day - first).days < 7 else None
            if key:
                txt = f"{r['b']:%H:%M}–{r['e']:%H:%M} OS {r['number']} {r['customer']}" + (f" (+{r['travel_min']} min)" if r["travel_min"] else "")
                tech[key] = (tech[key] + " · " if tech[key] else "") + txt
    ana.table(list(techs.values()), title=f"Agenda de {first:%d/%m} a {(last - datetime.timedelta(days=1)):%d/%m}")
    return {"technicians": len(techs), "visits": sum(1 for r in rows if r["aid"])}
