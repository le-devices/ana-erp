# ana:description Carga × capacidade por recurso e semana, com sobrecarga e data sugerida
# ana:exposed yes
# ana:command carga
# ana:category Produção/Planejamento
"""RF-014-07, CA-014-04. Load = remaining standard hours of the operations of planned, released
and in-progress orders, in the week the order starts. Capacity = hours per day × working days
(holidays of the scheduler, resource exceptions) × efficiency. Above 100 % is an overload; a
simple finite-capacity pass (priority, then start date) suggests when each order really fits."""

import datetime
from decimal import Decimal

from ana_lib.production import common
from ana_lib.projects import consulting as C

PARAMS = {
    "weeks": {"type": "int", "default": 8, "label": "semanas"},
    "resource": {"type": "str", "label": "recurso (vazio = todos)", "lookup": {"program": "production.lookup", "params": {"kind": "resources"}}},
}
ZERO = Decimal(0)
SPILL_WEEKS = 26


def main(weeks=8, resource=None):
    weeks = max(1, min(int(weeks), 52))
    first = common.monday(datetime.date.today())
    span = [first + datetime.timedelta(weeks=k) for k in range(weeks + SPILL_WEEKS)]
    last_day = span[-1] + datetime.timedelta(days=6)
    resources = ana.sql("SELECT code, name, daily_hours, efficiency_pct FROM production.resource WHERE active "
                        "AND ($1::text IS NULL OR code = upper($1)) ORDER BY code", resource)
    codes = [r["code"] for r in resources]
    exceptions = {(r["resource_code"], r["day"]): r["hours"] for r in ana.sql(
        "SELECT resource_code, day, hours FROM production.resource_calendar WHERE resource_code = ANY($1) "
        "AND day BETWEEN $2 AND $3", codes, first, last_day)}
    cal = C.Calendar(first, last_day)
    capacity = {}
    for r in resources:
        for wk in span:
            total = ZERO
            for k in range(7):
                d = wk + datetime.timedelta(days=k)
                if (r["code"], d) in exceptions:
                    total += Decimal(exceptions[(r["code"], d)])
                elif cal.is_workday(d):
                    total += Decimal(r["daily_hours"])
            capacity[(r["code"], wk)] = (total * Decimal(r["efficiency_pct"]) / 100).quantize(Decimal("0.01"))
    ops = ana.sql("SELECT w.number, w.priority, w.start_date, w.due_date, p.code AS item, op.resource_code, op.seq, "
                  "  greatest(op.std_hours - op.actual_hours, 0) AS hours "
                  "FROM production.order_operation op JOIN production.work_order w ON w.id = op.order_id "
                  "JOIN base.product p ON p.id = w.product_id "
                  "WHERE w.status IN ('planned', 'released', 'in_progress') AND op.resource_code = ANY($1) "
                  "  AND op.std_hours > op.actual_hours ORDER BY w.priority, w.start_date, w.number, op.seq", codes)
    load = {}
    for o in ops:
        wk = max(first, common.monday(o["start_date"]))
        load[(o["resource_code"], wk)] = load.get((o["resource_code"], wk), ZERO) + Decimal(o["hours"])

    # Finite capacity: in priority order, each operation takes the free hours from its start week on.
    free = dict(capacity)
    moves = []
    for o in ops:
        start = max(first, common.monday(o["start_date"]))
        left = Decimal(o["hours"])
        placed_first = placed_last = None
        for wk in span:
            if wk < start or left <= 0:
                continue
            take = min(free.get((o["resource_code"], wk), ZERO), left)
            if take > 0:
                free[(o["resource_code"], wk)] -= take
                left -= take
                placed_first = placed_first or wk
                placed_last = wk
        if left > 0 or placed_last is None or placed_last > start:
            moves.append({"ordem": o["number"], "item": o["item"], "recurso": o["resource_code"], "operação": o["seq"],
                          "horas": o["hours"], "início planejado": o["start_date"],
                          "início possível": placed_first, "término possível": (placed_last + datetime.timedelta(days=4))
                          if placed_last else None, "sem capacidade no horizonte": "sim" if left > 0 else ""})

    shown = span[:weeks]
    rows, over = [], 0
    for r in resources:
        row = {"recurso": f"{r['code']} — {r['name']}"}
        for wk in shown:
            cap, ld = capacity[(r["code"], wk)], load.get((r["code"], wk), ZERO)
            pct = (ld / cap * 100).quantize(Decimal("1")) if cap else (Decimal(999) if ld else ZERO)
            over += 1 if pct > 100 else 0
            row[f"{wk:%d/%m}"] = f"{pct}% ({ld:.1f}/{cap:.1f} h)" if ld or cap else "—"
        rows.append(row)
    ana.metrics([{"label": "Recursos", "value": len(resources)},
                 {"label": "Semanas com sobrecarga", "value": over, "status": "bad" if over else "ok"},
                 {"label": "Operações a reprogramar", "value": len(moves), "status": "warn" if moves else "ok"}])
    if resources:
        ana.chart(type="column", title="Carga × capacidade (horas)", subtitle="por semana, todos os recursos",
                  x=[f"{wk:%d/%m}" for wk in shown], format="hours",
                  series=[{"name": "Carga", "values": [sum((load.get((c, wk), ZERO) for c in codes), ZERO) for wk in shown]},
                          {"name": "Capacidade", "values": [sum((capacity[(c, wk)] for c in codes), ZERO) for wk in shown]}])
    ana.table(rows, title="Utilização por recurso e semana", empty="Nenhum recurso com carga no horizonte.",
              empty_action={"label": "Cadastrar recurso", "program": "production.save_resource"})
    ana.table(moves, title="Datas sugeridas (capacidade finita)" if moves else "Tudo cabe na capacidade",
              empty="Nenhuma data precisa mudar.", empty_good=True)
    return {"load": [{"resource": c, "week": wk, "hours": load.get((c, wk), ZERO), "capacity": capacity[(c, wk)],
                      "pct": (load.get((c, wk), ZERO) / capacity[(c, wk)] * 100).quantize(Decimal("1")) if capacity[(c, wk)] else None}
                     for c in codes for wk in shown],
            "moves": moves}
