# ana:description Capacidade de serviços: horas alocadas × disponíveis por colaborador e por perfil
# ana:exposed yes
# ana:command capacidade
"""RF-014-08, CA-014-05. Demand = weekly allocations of all projects (spec 021); capacity =
weekly hours × working days (holidays) minus absences. By profile, allocations still without a
person count as demand of the profile. Never shows hourly costs (confidential)."""

import datetime
from decimal import Decimal

from ana_lib.production import common
from ana_lib.projects import consulting as C

PARAMS = {
    "weeks": {"type": "int", "default": 4, "label": "semanas"},
    "start": {"type": "date", "label": "a partir de (vazio = esta semana)"},
}
ZERO = Decimal(0)


def main(weeks=4, start=None):
    weeks = max(1, min(int(weeks), 26))
    first = common.monday(start or datetime.date.today())
    span = [first + datetime.timedelta(weeks=k) for k in range(weeks)]
    people = ana.sql("SELECT id, name, profile FROM projects.employee WHERE active ORDER BY name")
    ids = [p["id"] for p in people]
    cap = C.week_capacity(ids, span)
    alloc = C.allocated(ids, span)
    open_profile = {(r["profile"], r["week"]): r["hours"] for r in ana.sql(
        "SELECT profile, week, sum(hours) AS hours FROM projects.allocation WHERE employee_id IS NULL AND week = ANY($1::date[]) "
        "GROUP BY 1, 2", span)}
    rows, overloaded = [], []
    for p in people:
        row = {"colaborador": p["name"], "perfil": p["profile"]}
        for wk in span:
            c, a = cap.get((p["id"], wk), ZERO), alloc.get((p["id"], wk), ZERO)
            pct = (Decimal(a) / c * 100).quantize(Decimal("1")) if c else (Decimal(999) if a else ZERO)
            row[f"{wk:%d/%m}"] = f"{pct}% ({Decimal(a):.1f}/{c:.1f} h)"
            if a > c:
                overloaded.append({"colaborador": p["name"], "semana": wk, "alocado": a, "disponível": c, "excesso": a - c})
        rows.append(row)
    profiles = sorted({p["profile"] for p in people} | {k[0] for k in open_profile})
    prow = []
    for pr in profiles:
        row = {"perfil": pr}
        for wk in span:
            c = sum((cap.get((p["id"], wk), ZERO) for p in people if p["profile"] == pr), ZERO)
            a = sum((Decimal(alloc.get((p["id"], wk), ZERO)) for p in people if p["profile"] == pr), ZERO) \
                + Decimal(open_profile.get((pr, wk), ZERO))
            row[f"{wk:%d/%m}"] = f"{(a / c * 100).quantize(Decimal('1')) if c else '—'}% ({a:.1f}/{c:.1f} h)"
        prow.append(row)
    ana.metrics([{"label": "Colaboradores", "value": len(people)},
                 {"label": "Sobrecargas (pessoa × semana)", "value": len(overloaded), "status": "bad" if overloaded else "ok"}])
    ana.table(overloaded, title="Sobrecarregados" if overloaded else "Ninguém acima da capacidade")
    ana.table(rows, title="Por colaborador (alocado / disponível)")
    ana.table(prow, title="Por perfil (inclui alocação ainda sem pessoa)")
    return {"overloaded": [{"employee": o["colaborador"], "week": o["semana"], "allocated": o["alocado"],
                            "capacity": o["disponível"]} for o in overloaded]}
