# ana:description Cálculos de consultoria: calendário útil, caminho crítico, valor agregado, capacidade
# ana:kind library
"""Spec 021. Everything here is computed on read and writes nothing (P15):
the schedule of a 2,000-activity project takes milliseconds.

- Calendar: working days are Monday–Friday minus scheduler.holiday.
- Schedule (CPM): forward and backward pass over activities (finish-to-start
  with lag). Forecast mode uses today and the progress of each activity.
- Earned value in hours (and money by profile rate).
- Capacity: weekly hours × working days of the week / 5, minus absences.
"""

import datetime
import math
from decimal import Decimal, ROUND_HALF_UP

ONE_DAY = datetime.timedelta(days=1)
ZERO = Decimal("0")


def monday(d):
    return d - datetime.timedelta(days=d.weekday())


def q2(v):
    return Decimal(v).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


# ---------------------------------------------------------------- calendar

class Calendar:
    """Working-day arithmetic over an index of working days."""

    def __init__(self, start, end):
        self._holidays = {r["day"] for r in ana.sql(
            "SELECT day FROM scheduler.holiday WHERE day BETWEEN $1 AND $2", start, end)}
        self._start, self._end = start, end
        self._days, self._index = [], {}
        d = start
        while d <= end:
            if d.weekday() < 5 and d not in self._holidays:
                self._index[d] = len(self._days)
                self._days.append(d)
            d += ONE_DAY

    @classmethod
    def around(cls, *dates, before=400, after=1500):
        dates = [d for d in dates if d]
        lo, hi = min(dates), max(dates)
        return cls(lo - datetime.timedelta(days=before), hi + datetime.timedelta(days=after))

    def is_workday(self, d):
        return d in self._index

    def roll(self, d):
        """The working day itself or the next one."""
        while d not in self._index:
            d += ONE_DAY
            if d > self._end:
                raise ana.Error("CALENDAR_RANGE", "data fora do horizonte do calendário")
        return d

    def idx(self, d):
        return self._index[self.roll(d)]

    def day(self, i):
        if i < 0 or i >= len(self._days):
            raise ana.Error("CALENDAR_RANGE", "data fora do horizonte do calendário")
        return self._days[i]

    def add(self, d, n):
        """n working days after the working day d (negative: before)."""
        return self.day(self.idx(d) + n)

    def count(self, a, b):
        """Working days in [a, b]."""
        if b < a:
            return 0
        return sum(1 for d in self._days_between(a, b))

    def diff(self, a, b):
        """Working days from a to b (b − a on the working-day index)."""
        return self.idx(b) - self.idx(a)

    def _days_between(self, a, b):
        i = self.idx(a)
        while i < len(self._days) and self._days[i] <= b:
            yield self._days[i]
            i += 1


# ---------------------------------------------------------------- plan

def load_plan(project_id):
    tasks = ana.sql(
        "SELECT t.*, e.name AS owner_name FROM projects.task t "
        "LEFT JOIN projects.employee e ON e.id = t.owner_employee_id "
        "WHERE t.project_id = $1 AND t.active ORDER BY t.seq, t.code", project_id)
    deps = ana.sql(
        "SELECT d.task_id, d.predecessor_id, d.lag_days FROM projects.task_dependency d "
        "JOIN projects.task t ON t.id = d.task_id WHERE t.project_id = $1", project_id)
    return tasks, deps


def duration(t, cal=None):
    if t["duration_days"] is not None:
        return int(t["duration_days"])
    if t["planned_start"] and t["planned_finish"] and cal:
        return max(cal.count(t["planned_start"], t["planned_finish"]), 1)
    hours = t["planned_hours"] or ZERO
    return max(int(math.ceil(hours / 8)), 1)


def topo_order(nodes, preds):
    """Kahn's algorithm; raises DEPENDENCY_CYCLE."""
    indeg = {n: 0 for n in nodes}
    succ = {n: [] for n in nodes}
    for n, ps in preds.items():
        for p, _ in ps:
            if p in indeg:
                indeg[n] += 1
                succ[p].append(n)
    ready = [n for n in nodes if indeg[n] == 0]
    out = []
    while ready:
        n = ready.pop(0)
        out.append(n)
        for s in succ[n]:
            indeg[s] -= 1
            if indeg[s] == 0:
                ready.append(s)
    if len(out) != len(nodes):
        raise ana.Error("DEPENDENCY_CYCLE", "as dependências formam um ciclo")
    return out, succ


def schedule(project, tasks=None, deps=None, today=None, forecast=True):
    """CPM. Returns {"items": {task_id: {...}}, "start", "finish", "calendar"}.

    forecast=False: the plan as drawn (no today, no progress).
    """
    if tasks is None:
        tasks, deps = load_plan(project["id"])
    today = today or datetime.date.today()
    acts = {t["id"]: t for t in tasks if t["kind"] == "activity"}
    starts = [t["planned_start"] for t in acts.values() if t["planned_start"]]
    start = project["start_date"] or (min(starts) if starts else today)
    cal = Calendar.around(start, today, *(t["planned_finish"] for t in acts.values()))
    preds = {i: [] for i in acts}
    for d in deps or []:
        if d["task_id"] in acts and d["predecessor_id"] in acts:
            preds[d["task_id"]].append((d["predecessor_id"], d["lag_days"]))
    order, succ = topo_order(list(acts), preds)
    start = cal.roll(start)
    now = cal.roll(today)
    es, ef = {}, {}
    for i in order:
        t = acts[i]
        dur = duration(t, cal)
        earliest = start
        for p, lag in preds[i]:
            earliest = max(earliest, cal.add(ef[p], 1 + lag))
        if t["planned_start"]:
            earliest = max(earliest, cal.roll(t["planned_start"]))
        if not forecast:
            es[i] = earliest
            ef[i] = cal.add(earliest, max(dur - 1, 0))
            continue
        if t["status"] == "done":
            es[i] = cal.roll(t["actual_start"] or earliest)
            ef[i] = cal.roll(t["actual_finish"] or cal.add(es[i], max(dur - 1, 0)))
        elif t["status"] in ("doing", "review"):
            es[i] = cal.roll(t["actual_start"] or min(earliest, now))
            remaining = int(math.ceil(dur * (1 - float(t["percent_complete"]) / 100)))
            base = max(now, es[i])
            ef[i] = max(cal.add(base, max(remaining - 1, 0)), es[i])
        else:
            es[i] = max(earliest, now)
            ef[i] = cal.add(es[i], max(dur - 1, 0))
    finish = max(ef.values()) if ef else start
    lf, ls = {}, {}
    for i in reversed(order):
        dur = duration(acts[i], cal)
        succs = succ[i]
        if succs:
            lf[i] = min(cal.add(ls[s], -1 - lag) for s in succs
                        for p, lag in preds[s] if p == i)
        else:
            lf[i] = finish
        ls[i] = cal.add(lf[i], -max(dur - 1, 0))
    items = {}
    for i in order:
        t = acts[i]
        flt = cal.diff(ef[i], lf[i])
        done = forecast and t["status"] == "done"
        items[i] = {"es": es[i], "ef": ef[i], "ls": ls[i], "lf": lf[i], "float": flt,
                    "critical": (not done) and flt <= 0,
                    "late": forecast and not done and t["planned_finish"] is not None
                            and ef[i] > t["planned_finish"]}
    # Phases: envelope of their activities.
    for t in tasks:
        if t["kind"] == "phase":
            kids = [items[c["id"]] for c in tasks if c["parent_id"] == t["id"] and c["id"] in items]
            if kids:
                items[t["id"]] = {"es": min(k["es"] for k in kids), "ef": max(k["ef"] for k in kids),
                                  "critical": any(k["critical"] for k in kids),
                                  "late": any(k["late"] for k in kids)}
    return {"items": items, "start": start, "finish": finish, "calendar": cal}


# ---------------------------------------------------------------- earned value

def latest_baseline(project_id):
    return ana.sql_one("SELECT * FROM projects.baseline WHERE project_id = $1 ORDER BY number DESC LIMIT 1",
                       project_id)


def rates(project_id):
    rows = ana.sql(
        "SELECT r.code, COALESCE(pr.hourly_rate, r.hourly_rate) AS rate FROM projects.rate_profile r "
        "LEFT JOIN projects.project_rate pr ON pr.profile = r.code AND pr.project_id = $1", project_id)
    return {r["code"]: r["rate"] for r in rows}


def progress(project, today=None):
    """Earned value by activity, phase and project (hours; value by profile rate)."""
    today = today or datetime.date.today()
    tasks, deps = load_plan(project["id"])
    base = latest_baseline(project["id"])
    base_items = {}
    if base:
        for b in ana.sql("SELECT * FROM projects.baseline_item WHERE baseline_id = $1", base["id"]):
            base_items[b["task_id"]] = b
    plan = schedule(project, tasks, deps, today, forecast=False)
    cal = plan["calendar"]
    logged = {r["task_id"]: r["hours"] for r in ana.sql(
        "SELECT task_id, sum(hours) AS hours FROM projects.time_entry "
        "WHERE project_id = $1 AND status <> 'rejected' GROUP BY task_id", project["id"])}
    rate = rates(project["id"])
    acts = []
    for t in tasks:
        if t["kind"] != "activity":
            continue
        b = base_items.get(t["id"])
        bac = Decimal(b["planned_hours"]) if b else Decimal(t["planned_hours"] or 0)
        ps = (b and b["planned_start"]) or t["planned_start"] or plan["items"][t["id"]]["es"]
        pf = (b and b["planned_finish"]) or t["planned_finish"] or plan["items"][t["id"]]["ef"]
        if today < ps:
            frac = Decimal(0)
        elif today >= pf:
            frac = Decimal(1)
        else:
            total = max(cal.count(ps, pf), 1)
            frac = Decimal(cal.count(ps, today)) / Decimal(total)
        pct = Decimal(t["percent_complete"]) / 100
        hr = rate.get(t["profile"]) or ZERO
        acts.append({"id": t["id"], "code": t["code"], "name": t["name"], "parent_id": t["parent_id"],
                     "bac": bac, "pv": bac * frac, "ev": bac * pct, "ac": Decimal(logged.get(t["id"]) or 0),
                     "rate": hr, "percent": Decimal(t["percent_complete"])})
    phases = {t["id"]: t for t in tasks if t["kind"] == "phase"}
    groups = {}
    for a in acts:
        groups.setdefault(a["parent_id"], []).append(a)
    rows = [indicators(phases[k]["code"] if k in phases else "—",
                       phases[k]["name"] if k in phases else "(sem fase)", v)
            for k, v in sorted(groups.items(), key=lambda kv: (phases[kv[0]]["seq"], phases[kv[0]]["code"])
                               if kv[0] in phases else (10 ** 9, ""))]
    total = indicators(project["code"], project["name"], acts)
    return {"phases": rows, "project": total, "activities": acts, "baseline": base}


def indicators(code, name, acts):
    bac = sum((a["bac"] for a in acts), ZERO)
    pv = sum((a["pv"] for a in acts), ZERO)
    ev = sum((a["ev"] for a in acts), ZERO)
    ac = sum((a["ac"] for a in acts), ZERO)
    spi = (ev / pv) if pv else None
    cpi = (ev / ac) if ac else None
    eac = (bac / cpi) if cpi else None
    value_bac = sum((a["bac"] * a["rate"] for a in acts), ZERO)
    value_ev = sum((a["ev"] * a["rate"] for a in acts), ZERO)
    alerts = []
    if cpi is not None and cpi < Decimal("0.9"):
        alerts.append("custo acima do planejado (IDC < 0,9)")
    if spi is not None and spi < Decimal("0.9"):
        alerts.append("atraso em relação ao planejado (IDP < 0,9)")
    return {"code": code, "name": name, "bac_hours": q2(bac), "pv_hours": q2(pv), "ev_hours": q2(ev),
            "ac_hours": q2(ac), "percent_complete": q2(ev / bac * 100) if bac else ZERO,
            "hours_consumed_pct": q2(ac / bac * 100) if bac else ZERO,
            "spi": q2(spi) if spi is not None else None, "cpi": q2(cpi) if cpi is not None else None,
            "eac_hours": q2(eac) if eac is not None else None,
            "bac_value": q2(value_bac), "ev_value": q2(value_ev), "alerts": alerts}


# ---------------------------------------------------------------- capacity

def week_capacity(employees, weeks):
    """{(employee_id, week): hours available} for the given employees and Mondays."""
    if not employees or not weeks:
        return {}
    lo, hi = min(weeks), max(weeks) + datetime.timedelta(days=6)
    cal = Calendar(lo, hi)
    rows = ana.sql("SELECT id, weekly_hours FROM projects.employee WHERE id = ANY($1::int[])", list(employees))
    weekly = {r["id"]: Decimal(r["weekly_hours"]) for r in rows}
    absences = ana.sql("SELECT employee_id, from_date, to_date FROM projects.absence "
                       "WHERE employee_id = ANY($1::int[]) AND to_date >= $2 AND from_date <= $3",
                       list(employees), lo, hi)
    out = {}
    for e in employees:
        off = [(a["from_date"], a["to_date"]) for a in absences if a["employee_id"] == e]
        for w in weeks:
            days = [w + datetime.timedelta(days=k) for k in range(5)]
            work = [d for d in days if cal.is_workday(d) and not any(a <= d <= b for a, b in off)]
            out[(e, w)] = q2(weekly.get(e, Decimal(40)) * len(work) / 5)
    return out


def allocated(employees, weeks):
    """{(employee_id, week): hours allocated in all projects}."""
    if not employees or not weeks:
        return {}
    rows = ana.sql("SELECT employee_id, week, sum(hours) AS hours FROM projects.allocation "
                   "WHERE employee_id = ANY($1::int[]) AND week = ANY($2::date[]) GROUP BY 1, 2",
                   list(employees), list(weeks))
    return {(r["employee_id"], r["week"]): r["hours"] for r in rows}


def overallocation(employees, weeks):
    """[{employee_id, week, capacity, allocated, excess}] where allocated > capacity."""
    cap = week_capacity(employees, weeks)
    alloc = allocated(employees, weeks)
    out = []
    for (e, w), c in sorted(cap.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        a = alloc.get((e, w), ZERO)
        if a > c:
            out.append({"employee_id": e, "week": w, "capacity": c, "allocated": a, "excess": q2(a - c)})
    return out


def suggest_moves(employee, week, excess, horizon=8):
    """Free capacity in the following weeks to absorb an excess (suggestion only)."""
    weeks = [week + datetime.timedelta(weeks=k) for k in range(1, horizon + 1)]
    cap = week_capacity([employee], weeks)
    alloc = allocated([employee], weeks)
    out, left = [], Decimal(excess)
    for w in weeks:
        free = cap[(employee, w)] - alloc.get((employee, w), ZERO)
        if free > 0 and left > 0:
            take = min(free, left)
            out.append({"week": w, "hours": q2(take)})
            left -= take
    return out


def distribute(total, start, finish, cal=None):
    """Spreads hours over the working weeks of [start, finish], proportional to working days,
    in multiples of 0.25 h; the remainder goes to the last week. Pass `cal` to reuse a calendar."""
    if cal is None or not (cal._start <= start and finish <= cal._end):
        cal = Calendar(start - ONE_DAY, finish + ONE_DAY)
    weeks = {}
    d = start
    while d <= finish:
        if cal.is_workday(d):
            weeks[monday(d)] = weeks.get(monday(d), 0) + 1
        d += ONE_DAY
    days = sum(weeks.values())
    if not days:
        raise ana.Error("NO_WORKDAYS", "o período da atividade não tem dias úteis")
    total = Decimal(total)
    out, used = {}, ZERO
    keys = sorted(weeks)
    for w in keys[:-1]:
        h = (total * weeks[w] / days * 4).to_integral_value(rounding=ROUND_HALF_UP) / 4
        out[w] = h
        used += h
    out[keys[-1]] = total - used
    return out


# ---------------------------------------------------------------- baselines

def create_baseline(p, reason, change_id=None):
    """RF-021-06: freezes the current plan as the next baseline; activates a proposal."""
    tasks, deps = load_plan(p["id"])
    if not any(t["kind"] == "activity" for t in tasks):
        raise ana.Error("EMPTY_PLAN", "o projeto não tem atividades para aprovar")
    plan = schedule(p, tasks, deps, forecast=False)
    rate = rates(p["id"])
    number = ana.sql_value("SELECT COALESCE(max(number), 0) + 1 FROM projects.baseline WHERE project_id = $1", p["id"])
    acts = [t for t in tasks if t["kind"] == "activity"]
    total_hours = sum((t["planned_hours"] or 0) for t in acts)
    total_value = sum(((t["planned_hours"] or 0) * (rate.get(t["profile"]) or 0)) for t in acts)
    bid = ana.sql_value(
        "INSERT INTO projects.baseline (project_id, number, reason, change_id, total_hours, total_value, "
        "  finish_date, created_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id",
        p["id"], number, reason, change_id, total_hours, q2(total_value), plan["finish"], ana.context.user)
    by_id = {t["id"]: t for t in tasks}
    ana.sql_batch(
        "INSERT INTO projects.baseline_item (baseline_id, task_id, code, name, kind, parent_code, planned_hours, "
        "  planned_start, planned_finish, planned_value) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        [[bid, t["id"], t["code"], t["name"], t["kind"], by_id[t["parent_id"]]["code"] if t["parent_id"] else None,
          t["planned_hours"] or 0, plan["items"].get(t["id"], {}).get("es"), plan["items"].get(t["id"], {}).get("ef"),
          q2((t["planned_hours"] or 0) * (rate.get(t["profile"]) or 0))] for t in tasks])
    if p["status"] == "proposal":
        ana.sql_exec("UPDATE projects.project SET status = 'active' WHERE id = $1", p["id"])
    if p["start_date"] is None:
        ana.sql_exec("UPDATE projects.project SET start_date = $2 WHERE id = $1", p["id"], plan["start"])
    ana.log(f"linha de base {number}: {total_hours} h, término {plan['finish'].isoformat()}")
    return {"project": p["code"], "baseline": number, "total_hours": total_hours, "finish": plan["finish"]}
