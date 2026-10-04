# ana:description Finanças do projeto: lucro pela alocação, projeção de viabilidade, cenários
# ana:kind library
"""Spec 021, RF-021-12..15. Computed on read (P15). Cost and profit are
confidential: callers must check access.can_manage (RNF-021-02).

Revenue follows how spec 008 invoices: billable hours × project rate of the
profile, milestones and rebillable expenses (with markup). Fixed price
counts the milestones (or the budget when there are none) instead of hours.

Labor per activity: allocated hours when the activity has allocation,
otherwise its planned hours (by the activity profile). In execution, the
actual part (time entries, expenses) is added to what remains: allocations
from the current week on and planned hours still not logged.
"""

import datetime
from decimal import Decimal

from ana_lib.projects import consulting as C

ZERO = Decimal(0)
HUNDRED = Decimal(100)


def policy():
    return ana.sql_one("SELECT target_margin_pct, min_margin_pct, overhead_pct FROM projects.policy WHERE id = 1") or \
        {"target_margin_pct": Decimal(30), "min_margin_pct": Decimal(15), "overhead_pct": ZERO}


def profile_costs():
    rows = ana.sql(
        "SELECT r.code, COALESCE(r.standard_cost, avg(e.hourly_cost) FILTER (WHERE e.active)) AS cost "
        "FROM projects.rate_profile r LEFT JOIN projects.employee e ON e.profile = r.code GROUP BY r.code")
    return {r["code"]: Decimal(r["cost"] or 0) for r in rows}


def month(d):
    return d.replace(day=1)


def add_months(d, n):
    y, m = divmod(d.month - 1 + n, 12)
    return d.replace(year=d.year + y, month=m + 1, day=1)


def months_between(a, b):
    out, m = [], month(a)
    while m <= month(b):
        out.append(m)
        m = add_months(m, 1)
    return out


def factor(pct):
    return 1 + Decimal(pct or 0) / HUNDRED


def projection(p, adj=None, today=None):
    adj = {"rate_pct": 0, "hours_pct": 0, "cost_pct": 0, "delay_weeks": 0, **(adj or {})}
    today = today or datetime.date.today()
    executing = p["status"] != "proposal"
    rate_f, hours_f, cost_f = factor(adj["rate_pct"]), factor(adj["hours_pct"]), factor(adj["cost_pct"])
    shift = datetime.timedelta(weeks=int(adj["delay_weeks"] or 0))
    pol = policy()
    rates = C.rates(p["id"])
    pcost = profile_costs()
    tasks, deps = C.load_plan(p["id"])
    sched = C.schedule(p, tasks, deps, today, forecast=executing)
    this_week = C.monday(today)
    employees = {r["id"]: r for r in ana.sql(
        "SELECT e.id, e.name, e.hourly_cost, COALESCE(pm.profile, e.profile) AS profile FROM projects.employee e "
        "LEFT JOIN projects.project_member pm ON pm.employee_id = e.id AND pm.project_id = $1", p["id"])}
    allocs = ana.sql("SELECT task_id, week, employee_id, profile, hours FROM projects.allocation WHERE project_id = $1",
                     p["id"])
    by_task = {}
    for a in allocs:
        by_task.setdefault(a["task_id"], []).append(a)
    logged = {r["task_id"]: r["hours"] for r in ana.sql(
        "SELECT task_id, sum(hours) AS hours FROM projects.time_entry WHERE project_id = $1 AND status <> 'rejected' "
        "GROUP BY task_id", p["id"])} if executing else {}
    hourly_revenue = p["billing"] in ("hourly", "mixed")
    warnings = []
    monthly = {}
    people = {}

    def book(when, revenue=ZERO, cost=ZERO):
        m = monthly.setdefault(month(when), {"revenue": ZERO, "cost": ZERO})
        m["revenue"] += revenue
        m["cost"] += cost

    def person(key, name, hours, cost, revenue):
        r = people.setdefault(key, {"who": name, "hours": ZERO, "cost": ZERO, "revenue": ZERO})
        r["hours"] += hours
        r["cost"] += cost
        r["revenue"] += revenue

    labor_cost = labor_revenue = hours_total = ZERO
    pending_revenue = []          # [when, revenue, billable hours] of the remaining/planned labor
    # ---------------------------------------------------------------- actual (execution)
    actual = {"labor_cost": ZERO, "labor_revenue": ZERO, "hours": ZERO, "expenses": ZERO, "invoiced": ZERO}
    if executing:
        for r in ana.sql(
                "SELECT t.entry_date, t.hours, t.billable, t.employee_id, e.name, "
                "  COALESCE(t.hourly_cost, e.hourly_cost) AS cost, COALESCE(t.hourly_rate, pr.hourly_rate, rp.hourly_rate) AS rate "
                "FROM projects.time_entry t JOIN projects.employee e ON e.id = t.employee_id "
                "JOIN projects.rate_profile rp ON rp.code = t.profile "
                "LEFT JOIN projects.project_rate pr ON pr.project_id = t.project_id AND pr.profile = t.profile "
                "WHERE t.project_id = $1 AND t.status <> 'rejected'", p["id"]):
            cost = r["hours"] * r["cost"]
            rev = r["hours"] * r["rate"] if (r["billable"] and hourly_revenue) else ZERO
            book(r["entry_date"], rev, cost)
            person(("e", r["employee_id"]), r["name"], r["hours"], cost, rev)
            actual["labor_cost"] += cost
            actual["labor_revenue"] += rev
            actual["hours"] += r["hours"]
        for x in ana.sql("SELECT expense_date, quantity * unit_cost AS cost, rebillable, markup_pct "
                         "FROM projects.expense WHERE project_id = $1", p["id"]):
            rev = x["cost"] * (1 + x["markup_pct"] / HUNDRED) if x["rebillable"] else ZERO
            book(x["expense_date"], rev, x["cost"])
            actual["expenses"] += x["cost"]
        actual["invoiced"] = ana.sql_value("SELECT COALESCE(sum(total), 0) FROM projects.invoice "
                                           "WHERE project_id = $1 AND status = 'issued'", p["id"])
        labor_cost += actual["labor_cost"]
        labor_revenue += actual["labor_revenue"]
        hours_total += actual["hours"]

    # ---------------------------------------------------------------- remaining / planned labor
    all_costs = [Decimal(e["hourly_cost"]) for e in employees.values() if e["hourly_cost"]]
    fallback_cost = (sum(all_costs) / len(all_costs)) if all_costs else ZERO
    for t in tasks:
        if t["kind"] != "activity" or (executing and t["status"] == "done"):
            continue
        rows = by_task.get(t["id"], [])
        chunks = []          # (week, hours, cost_rate, bill_rate, person_key, person_name)
        if rows:
            for a in rows:
                if executing and a["week"] < this_week:
                    continue
                if a["employee_id"] is not None:
                    e = employees.get(a["employee_id"])
                    chunks.append((a["week"], a["hours"], Decimal(e["hourly_cost"] or 0),
                                   rates.get(e["profile"]) or ZERO, ("e", e["id"]), e["name"]))
                else:
                    chunks.append((a["week"], a["hours"], pcost.get(a["profile"], ZERO), rates.get(a["profile"]) or ZERO,
                                   ("p", a["profile"]), f"perfil {a['profile']}"))
        else:
            remaining = Decimal(t["planned_hours"] or 0) - Decimal(logged.get(t["id"]) or 0)
            if remaining > 0:
                prof = t["profile"]
                if prof is None:
                    warnings.append(f"atividade {t['code']} sem perfil nem alocação: custo médio da empresa")
                cost_rate = pcost.get(prof, fallback_cost) if prof else fallback_cost
                if prof and not cost_rate:
                    warnings.append(f"perfil {prof} sem custo padrão nem pessoas com custo: custo zero")
                s = sched["items"][t["id"]]
                start = max(s["es"], today) if executing else s["es"]
                finish = max(s["ef"], start)
                for w, h in C.distribute(remaining, start, finish, sched["calendar"]).items():
                    chunks.append((w, h, cost_rate, rates.get(prof) or ZERO, ("p", prof or "-"),
                                   f"perfil {prof}" if prof else "sem perfil"))
        for week, hours, cost_rate, bill_rate, key, name in chunks:
            # hours_pct is effort deviation from the estimate: it changes cost; billing follows the
            # planned scope (RF-021-14).
            h = hours * hours_f
            cost = h * cost_rate * cost_f
            rev = hours * bill_rate * rate_f if (t["billable"] and hourly_revenue) else ZERO
            pending_revenue.append([week + shift, rev, hours if rev else ZERO])
            book(week + shift, ZERO, cost)
            person(key, name, h, cost, rev)
            labor_cost += cost
            hours_total += h

    # Billable hours never go beyond the client's hour budget (the excess is not invoiced).
    billable = sum((x[2] for x in pending_revenue), ZERO)
    already = actual["hours"] if executing else ZERO
    scale = Decimal(1)
    if p["budget_hours"] and hourly_revenue and billable:
        room = max(Decimal(p["budget_hours"]) - already, ZERO)
        if billable > room:
            scale = room / billable
            warnings.append(f"{C.q2(billable - room)} h faturáveis acima do orçamento de {p['budget_hours']} h "
                            f"do cliente: não entram no faturamento")
    for when, rev, _ in pending_revenue:
        book(when, rev * scale)
        labor_revenue += rev * scale

    # ---------------------------------------------------------------- milestones and fixed price
    planned_finish = sched["finish"] + shift
    project_start = (p["start_date"] or sched["start"])
    milestone_revenue = ZERO
    milestones = ana.sql("SELECT amount, due_date, completed_on, status FROM projects.milestone WHERE project_id = $1",
                         p["id"])
    for m in milestones:
        amount = m["amount"] * (rate_f if m["status"] == "planned" else 1)
        when = m["completed_on"] or ((m["due_date"] or planned_finish) + (shift if m["status"] == "planned" else
                                                                          datetime.timedelta()))
        book(when, amount)
        milestone_revenue += amount
    if p["billing"] == "fixed" and not milestones and p["budget_amount"]:
        # Fixed price without milestones: recognized in proportion to labor cost by month.
        total_cost = sum((v["cost"] for v in monthly.values()), ZERO) or Decimal(1)
        budget = p["budget_amount"] * rate_f
        for v in monthly.values():
            v["revenue"] += budget * v["cost"] / total_cost
        milestone_revenue = budget

    # ---------------------------------------------------------------- planned expenses
    expense_cost = actual["expenses"]
    expense_revenue = ZERO
    months = months_between(today if executing else project_start, max(planned_finish, today if executing else
                                                                       project_start))
    for x in ana.sql("SELECT * FROM projects.planned_expense WHERE project_id = $1", p["id"]):
        markup = (1 + x["markup_pct"] / HUNDRED) if x["rebillable"] else ZERO
        if x["monthly"]:
            for m in months:
                book(m, x["amount"] * markup, x["amount"] * cost_f)
                expense_cost += x["amount"] * cost_f
                expense_revenue += x["amount"] * markup
        else:
            when = (x["expected_date"] or project_start) + shift
            if executing and when < month(today):
                continue
            book(when, x["amount"] * markup, x["amount"] * cost_f)
            expense_cost += x["amount"] * cost_f
            expense_revenue += x["amount"] * markup

    # ---------------------------------------------------------------- totals
    # Overhead: % of labor cost, booked in each month in proportion to that month's cost.
    overhead = labor_cost * pol["overhead_pct"] / HUNDRED
    month_cost = sum((v["cost"] for v in monthly.values()), ZERO)
    if overhead and month_cost:
        for v in monthly.values():
            v["cost"] += overhead * v["cost"] / month_cost
    revenue = labor_revenue + milestone_revenue + expense_revenue      # labor_revenue is 0 for fixed price
    taxes = revenue * p["service_tax_rate"]
    cost = labor_cost + expense_cost + overhead
    profit = revenue - taxes - cost
    margin = (profit / revenue * HUNDRED) if revenue else None
    if margin is None:
        verdict = "inviable"
        warnings.append("o projeto não gera receita com os parâmetros atuais")
    elif margin >= pol["target_margin_pct"]:
        verdict = "viable"
    elif margin >= pol["min_margin_pct"]:
        verdict = "attention"
    else:
        verdict = "inviable"
    # Monthly series with taxes; cumulative result and payback month.
    series, cum, payback = [], ZERO, None
    for m in sorted(monthly):
        v = monthly[m]
        tax = v["revenue"] * p["service_tax_rate"]
        result = v["revenue"] - tax - v["cost"]
        cum += result
        series.append({"month": m, "revenue": C.q2(v["revenue"]), "taxes": C.q2(tax), "cost": C.q2(v["cost"]),
                       "result": C.q2(result), "cumulative": C.q2(cum)})
    for i, s in enumerate(series):
        if all(x["cumulative"] >= 0 for x in series[i:]):
            payback = s["month"]
            break
    return {
        "project": p["code"], "status": p["status"], "billing": p["billing"], "executing": executing,
        "adjustments": adj, "hours": C.q2(hours_total),
        "revenue": C.q2(revenue), "taxes": C.q2(taxes), "net_revenue": C.q2(revenue - taxes),
        "labor_cost": C.q2(labor_cost), "expense_cost": C.q2(expense_cost), "overhead": C.q2(overhead),
        "cost": C.q2(cost), "profit": C.q2(profit), "margin_pct": C.q2(margin) if margin is not None else None,
        "verdict": verdict, "policy": pol, "start": project_start, "finish": planned_finish,
        "monthly": series, "payback_month": payback,
        "people": [{**v, "hours": C.q2(v["hours"]), "cost": C.q2(v["cost"]), "revenue": C.q2(v["revenue"])}
                   for v in sorted(people.values(), key=lambda r: -r["cost"])],
        "actual": {k: C.q2(v) for k, v in actual.items()}, "warnings": warnings,
    }


VERDICT = {"viable": ("viável", "ok"), "attention": ("atenção", "warn"), "inviable": ("inviável", "bad")}


# ---------------------------------------------------------------- scenarios (RF-021-14/14a)

SCENARIO_LABEL = {"base": "base", "optimistic": "otimista", "pessimistic": "pessimista"}
FIELDS = ("hours_pct", "cost_pct", "rate_pct", "delay_weeks")


def standard_scenarios(p):
    """Base, optimistic and pessimistic adjustments: project overrides, else company policy."""
    pol = ana.sql_one("SELECT * FROM projects.policy WHERE id = 1")
    own = {r["kind"]: r for r in ana.sql("SELECT * FROM projects.scenario WHERE project_id = $1 AND kind <> 'custom'",
                                         p["id"])}
    out = [("base", "base", {f: 0 for f in FIELDS})]
    for kind in ("optimistic", "pessimistic"):
        src = own.get(kind)
        adj = {f: (src[f] if src else pol[f"{kind}_{f}"]) for f in FIELDS}
        out.append((kind, SCENARIO_LABEL[kind] + (" (do projeto)" if src else ""), adj))
    return out


def scenarios(p, extra=None):
    """[(key, label, adjustments, projection)] — always base, optimistic, pessimistic; then custom ones."""
    items = standard_scenarios(p)
    for r in ana.sql("SELECT * FROM projects.scenario WHERE project_id = $1 AND kind = 'custom' ORDER BY name",
                     p["id"]):
        items.append((f"custom:{r['id']}", r["name"], {f: r[f] for f in FIELDS}))
    if extra:
        items.append(("simulation", "simulação", extra))
    return [(k, label, adj, projection(p, adj)) for k, label, adj in items]


def describe(adj):
    parts = []
    for f, label in (("hours_pct", "horas"), ("cost_pct", "custo"), ("rate_pct", "valor-hora")):
        if adj.get(f):
            parts.append(f"{label} {Decimal(adj[f]):+.0f}%")
    if adj.get("delay_weeks"):
        parts.append(f"atraso {adj['delay_weeks']} sem")
    return ", ".join(parts) or "plano"


def check_and_record(p, number, justification=None):
    """RF-021-15: before a baseline is kept, applies the margin policy and stores the projection in it.
    Below the minimum margin requires a justification (LOW_MARGIN)."""
    res = {k: r for k, _, _, r in scenarios(p)}
    base, pes = res["base"], res["pessimistic"]
    pol = base["policy"]
    low = base["margin_pct"] is None or base["margin_pct"] < pol["min_margin_pct"]
    if low and not (justification and len(justification.strip()) >= 10):
        raise ana.Error("LOW_MARGIN",
                        f"margem projetada {base['margin_pct'] if base['margin_pct'] is not None else '—'}% abaixo da "
                        f"mínima de {pol['min_margin_pct']}%: corrija valores, horas ou prazos, ou justifique "
                        f"(mínimo 10 caracteres)",
                        {"margin_pct": base["margin_pct"], "min_margin_pct": pol["min_margin_pct"],
                         "profit": base["profit"]})
    if pes["profit"] < 0:
        ana.log(f"atenção: no cenário pessimista o projeto dá prejuízo de {-pes['profit']}", "warning")
    ana.sql_exec("UPDATE projects.baseline SET projected_revenue = $3, projected_cost = $4, projected_profit = $5, "
                 "low_margin_justification = $6 WHERE project_id = $1 AND number = $2",
                 p["id"], number, base["revenue"], base["cost"], base["profit"],
                 justification.strip() if (low and justification) else None)
    return base
