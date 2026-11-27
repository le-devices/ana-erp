# ana:description Cenários: projeção base de caixa, operação e resultado, como um grafo de eventos datados
# ana:kind library
"""Spec 069 (T-069-02, D1; plan §2, §4, §8). The future from what is in the ERP, by the ERP's own rules:

- cash: bank balances, open bills, the sales orders turned into bills by their payment terms (finance.terms), the
  open purchases turned into payables, the taxes of what will be invoiced (tax engine), and what leaves the bank every
  month without a bill (measured);
- operation: when each purchase arrives, each production order ends and each order line can be delivered — supplies
  given to demands by date, the oldest first, level by level (the deepest components first);
- result: revenue, cost and margin by item, line (item group) and customer.

Every event keeps its document of origin and the events it waits for, with the slack between them (`after`), so a
scenario (spec 069, D3) moves only what depends on a shock. Delays are measured (12 months: customers by the bank
reconciliation, suppliers by the receipts), never guessed. Reads only: the projection runs as a rehearsal."""

import datetime
from decimal import Decimal, ROUND_HALF_UP

import ana

from ana_lib.finance import currency, terms
from ana_lib.production import common, mrp

ZERO = Decimal(0)
CENT = Decimal("0.01")
HISTORY_DAYS = 365
MIN_SAMPLE = 5
RECURRING_MONTHS = 3
RECURRING_DAY = 5
TAX_DAY = 20


def money(v):
    return Decimal(str(v or 0)).quantize(CENT, ROUND_HALF_UP)


class Graph:
    """The events of the projection. An event: id, kind, date (and base_date), amount (signed, reais, for cash),
    doc (its document), party, item, qty, after [(event id, slack days)], and what the kind needs."""

    CASH = ("cash_in", "cash_out", "bank_balance")

    def __init__(self, today, horizon_weeks, cash=True):
        self.today = today
        self.cash = cash
        self.horizon_weeks = horizon_weeks
        self.end = today + datetime.timedelta(weeks=horizon_weeks)
        self.events = []
        self.notes = []
        self.delays = []

    def add(self, kind, date, amount=ZERO, *, doc, after=(), **extra):
        if not self.cash and kind in self.CASH:
            return None                 # plan §7: without access to the company's cash, it is not even calculated
        e = {"id": len(self.events), "kind": kind, "date": date, "base_date": date, "amount": money(amount), "doc": doc,
             "after": [(p["id"], max(0, (date - p["date"]).days)) for p in after if p is not None], **extra}
        self.events.append(e)
        return e

    def note(self, text):
        if text not in self.notes:
            self.notes.append(text)


# ------------------------------------------------------------------ measured delays (plan §4)
# Customers: bank statement date − due date of the receivables reconciled; suppliers: receipt − promised date.
PAID = ("FROM finance.bill b JOIN finance.bank_match m ON m.bill_id = b.id "
        "JOIN finance.bank_statement_line s ON s.id = m.line_id "
        "WHERE b.kind = 'receivable' AND s.posted_on >= $1 AND s.posted_on <= $2")
RECEIVED = ("FROM supply.receipt r JOIN supply.receipt_line rl ON rl.receipt_id = r.id "
            "JOIN supply.purchase_order o ON o.id = r.order_id "
            "JOIN supply.purchase_order_line l ON l.order_id = o.id AND l.line = rl.order_line "
            "WHERE l.promised_date IS NOT NULL AND r.received_at >= $1 AND r.received_at::date <= $2")
DELAY_SQL = {
    "receivable": ("SELECT b.party_id AS party, percentile_disc(0.5) WITHIN GROUP (ORDER BY s.posted_on - b.due_date) AS d, "
                   "count(*)::int AS n " + PAID + " GROUP BY 1",
                   "SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY s.posted_on - b.due_date) AS d, count(*)::int AS n " + PAID),
    "supplier": ("SELECT o.supplier_id AS party, percentile_disc(0.5) WITHIN GROUP (ORDER BY r.received_at::date - l.promised_date) "
                 "AS d, count(*)::int AS n " + RECEIVED + " GROUP BY 1",
                 "SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY r.received_at::date - l.promised_date) AS d, count(*)::int AS n "
                 + RECEIVED),
}


class Delays:
    def __init__(self, today, kinds=("receivable", "supplier")):
        since = today - datetime.timedelta(days=HISTORY_DAYS)
        self.by = {"receivable": {}, "supplier": {}}
        self.company = {"receivable": (0, 0), "supplier": (0, 0)}
        for kind, (per_party, overall) in DELAY_SQL.items():
            if kind not in kinds:
                continue
            # ana:lint-ok sql_in_loop — two sources only (customers, suppliers)
            for r in ana.sql(per_party, since, today):
                self.by[kind][r["party"]] = (int(r["d"]), r["n"])
            # ana:lint-ok sql_in_loop — two sources only (customers, suppliers)
            c = ana.sql_one(overall, since, today)
            self.company[kind] = (int(c["d"]), c["n"]) if c and c["d"] is not None else (0, 0)

    def of(self, kind, party):
        """(days, where it came from)."""
        d, n = self.by[kind].get(party, (0, 0))
        if n >= MIN_SAMPLE:
            return d, f"{n} casos da própria parte"
        cd, cn = self.company[kind]
        if cn >= MIN_SAMPLE:
            return cd, f"mediana da empresa ({cn} casos)"
        return 0, "sem histórico suficiente"


# ------------------------------------------------------------------ the base
def build(horizon_weeks=26, today=None, hooks=None, cash=True):
    """The base projection (no shock). `hooks` (spec 069, scenarios: scenario.shocks) changes the sources before they
    are used, so a shock goes through the same rules as the base:
    - "bills", "purchase_lines", "sale_lines", "work_orders", "catalog": a source's rows, returned changed;
    - under "mrp", the hooks of production.mrp ("sales", "forecast", "purchases": its own rows);
    - "delay"(kind, party, days, at) → the days to use, or None when it never happens (kind "receivable"/"supplier");
    - "term_days": {"receive": n, "pay": n} added to the payment terms of the orders;
    - "price"(item, price, at) → the purchase price (in the order's currency) of what arrives at `at`;
    - "line_cost"(item, qty, at, cost) → the cost of an order line invoiced at `at`;
    - "tax_data": the tax rules to use (tax.engine.with_drafts).
    Without `cash` (plan §7), no cash event is calculated: no bank balance, bill or bank history is read."""
    hooks = hooks or {}

    def hook(name, rows):
        f = hooks.get(name)
        return f(rows) if f else rows

    today = today or datetime.date.today()
    g = Graph(today, horizon_weeks, cash)
    delays = Delays(today, ("receivable", "supplier") if cash else ("supplier",))
    rates = {}

    def brl(amount, cur, at):
        if (cur or "BRL") == "BRL":
            return money(amount)
        if (cur, at) not in rates:
            try:
                rates[(cur, at)] = currency.rate(cur, at)
            except ana.Error as e:
                g.note(e.message)
                rates[(cur, at)] = None
        r = rates[(cur, at)]
        return money(Decimal(str(amount)) * r) if r is not None else ZERO

    def delay(kind, party, used, at):
        d, why = delays.of(kind, party)
        if party not in used:
            used[party] = (d, why)
        f = hooks.get("delay")
        return f(kind, party, d, at) if f else d

    term_days = {"receive": 0, "pay": 0, **(hooks.get("term_days") or {})}
    price = hooks.get("price") or (lambda item, p, at: p)

    cust_used, supp_used = {}, {}

    # 1. Bank balances: the ledger account of each bank account (one per account, even if two banks share it).
    for r in ([] if not cash else ana.sql("SELECT b.account, string_agg(b.code, ', ' ORDER BY b.code) AS banks, "
                     "  (SELECT COALESCE(sum(l.debit - l.credit), 0) FROM finance.journal_line l WHERE l.account = b.account) AS balance "
                     "FROM finance.bank_account b WHERE b.active GROUP BY b.account ORDER BY b.account")):
        g.add("bank_balance", today, r["balance"], doc=f"saldo {r['banks']}")

    # 2. Open bills, at the due date plus the party's measured delay (never before today).
    for r in ([] if not cash else hook("bills", ana.sql("SELECT id, kind, party_id, document, due_date, amount FROM finance.bill "
                                                        "WHERE status = 'open' ORDER BY id"))):
        inflow = r["kind"] == "receivable"
        d = delay("receivable", r["party_id"], cust_used, r["due_date"]) if inflow else 0
        if d is None:
            g.note("há títulos a receber que, neste cenário, não entram")
            continue
        g.add("cash_in" if inflow else "cash_out", max(today, r["due_date"] + datetime.timedelta(days=d)),
              r["amount"] if inflow else -Decimal(r["amount"]), doc=f"título {r['document']}", party=r["party_id"],
              bill=r["id"], due=r["due_date"])

    # 3. Supplies and demands of goods, given by date (plan §2: pegging, the oldest first, deepest level first).
    levels = {r["item"]: r["lvl"] for r in ana.sql(
        "WITH RECURSIVE t AS (SELECT s.product_id AS item, 0 AS lvl FROM production.structure s WHERE s.active "
        "  UNION ALL SELECT l.component_id, t.lvl + 1 FROM t JOIN production.structure s ON s.product_id = t.item AND s.active "
        "  JOIN production.structure_line l ON l.structure_id = s.id WHERE t.lvl < 50) "
        "SELECT item, max(lvl) AS lvl FROM t GROUP BY item")}
    supplies, demands = {}, {}          # item -> [[date, qty, event or None]] / [[date, qty, key]]
    for r in ana.sql("SELECT m.product_id, sum(m.quantity) AS q FROM inventory.stock_movement m "
                     "JOIN base.product p ON p.id = m.product_id WHERE p.kind = 'goods' GROUP BY 1 HAVING sum(m.quantity) > 0"):
        supplies.setdefault(r["product_id"], []).append([today, Decimal(r["q"]), None])

    # Purchases: arrive at the promised date plus the supplier's delay; paid payment_days after.
    for r in hook("purchase_lines", ana.sql(
            "SELECT l.product_id, o.supplier_id, o.number, l.line, o.currency, o.payment_days, l.price, "
            "  COALESCE(l.promised_date, current_date) AS d, l.quantity - l.received_qty AS q "
            "FROM supply.purchase_order_line l JOIN supply.purchase_order o ON o.id = l.order_id "
            "WHERE o.status IN ('draft', 'sent', 'partially_received') AND l.received_qty < l.quantity ORDER BY o.number, l.line")):
        d = delay("supplier", r["supplier_id"], supp_used, r["d"])
        if d is None:
            g.note("há compras em aberto que, neste cenário, não chegam")
            continue
        at = max(today, r["d"] + datetime.timedelta(days=d))
        rec = g.add("receipt", at, doc=f"OC-{r['number']}/{r['line']}", party=r["supplier_id"], item=r["product_id"],
                    qty=Decimal(r["q"]), currency=r["currency"], promised=r["d"])
        supplies.setdefault(r["product_id"], []).append([at, Decimal(r["q"]), rec])
        pay = at + datetime.timedelta(days=r["payment_days"] + term_days["pay"])
        g.add("cash_out", pay, -brl(Decimal(r["q"]) * price(r["product_id"], Decimal(r["price"]), at), r["currency"], at), doc=f"OC-{r['number']}/{r['line']}",
              party=r["supplier_id"], item=r["product_id"], after=[rec])

    # What the planning would still propose (production.mrp, the MRP's own calculation).
    catalog = {r["product_id"]: r for r in hook("catalog", ana.sql(
        "SELECT product_id, supplier_id, price, currency FROM supply.supplier_item WHERE preferred"))}
    pay_days = ana.sql_value("SELECT default_payment_days FROM supply.policy WHERE id = 1") or 30
    for kind, item, qty, start, need, origin in mrp.compute(horizon_weeks, hooks=hooks.get("mrp"), today=today):
        at = max(today, need)
        if kind == "buy":
            c = catalog.get(item)
            if c and hooks.get("delay"):
                # A planned buy arrives when needed; a shock on its supplier moves it (or stops it) the same way.
                base_d = delays.of("supplier", c["supplier_id"])[0]
                d = hooks["delay"]("supplier", c["supplier_id"], base_d, at)
                if d is None:
                    g.note("há compras sugeridas pelo planejamento de um fornecedor que, neste cenário, não entrega")
                    continue
                at = max(today, at + datetime.timedelta(days=d - base_d))
            rec = g.add("receipt", at, doc="compra sugerida pelo planejamento", item=item, qty=Decimal(qty), planned=True,
                        party=c["supplier_id"] if c else None)
            if c:
                g.add("cash_out", at + datetime.timedelta(days=pay_days + term_days["pay"]), -brl(Decimal(qty) * price(item, Decimal(c["price"]), at), c["currency"], at),
                      doc="compra sugerida pelo planejamento", party=c["supplier_id"], item=item, after=[rec])
            else:
                g.note("há compras sugeridas pelo planejamento sem fornecedor preferencial: entram sem valor")
        else:
            rec = g.add("make", at, doc="produção sugerida pelo planejamento", item=item, qty=Decimal(qty), planned=True)
        supplies.setdefault(item, []).append([at, Decimal(qty), rec])

    # Production orders: wait for their components; end their duration after the last one arrives.
    comps_of = {}
    orders = {r["id"]: r for r in hook("work_orders", ana.sql(
        "SELECT id, number, product_id, quantity - good_qty - scrap_qty AS q, start_date, due_date FROM production.work_order "
        "WHERE status IN ('planned', 'released', 'in_progress') AND quantity > good_qty + scrap_qty"))}
    for r in ana.sql("SELECT c.order_id, c.product_id, c.qty_required - c.issued_qty AS q FROM production.order_component c "
                     "WHERE c.order_id = ANY($1) AND c.qty_required > c.issued_qty", sorted(orders)):
        demands.setdefault(r["product_id"], []).append([max(today, orders[r["order_id"]]["start_date"]), Decimal(r["q"]),
                                                        ("wo", r["order_id"], r["product_id"])])
        comps_of.setdefault(r["order_id"], []).append(r["product_id"])

    # Sales order lines: goods are given from what is available; services are delivered at the promised date.
    sales = hook("sale_lines", ana.sql(
        "SELECT o.id, o.number, o.customer_id, o.payment_term, o.order_date, i.line, i.product_id, i.quantity, i.amount, "
        "  COALESCE(i.promised_date, o.order_date) AS promised, p.kind, p.item_group "
        "FROM sales.sales_order o JOIN sales.sales_order_item i ON i.order_id = o.id JOIN base.product p ON p.id = i.product_id "
        "WHERE o.status = 'OPEN' ORDER BY o.number, i.line"))
    for s in sales:
        if s["kind"] == "goods":
            demands.setdefault(s["product_id"], []).append([max(today, s["promised"]), Decimal(s["quantity"]),
                                                            ("sale", s["id"], s["line"])])

    ready = {}                          # demand key -> (date it can be met, [supply events])
    made = {}                           # work order id -> its "make" event
    for item in sorted(set(supplies) | set(demands) | {o["product_id"] for o in orders.values()},
                       key=lambda i: -levels.get(i, 0)):
        for o in (o for o in orders.values() if o["product_id"] == item):
            comps = [ready[("wo", o["id"], c)] for c in comps_of.get(o["id"], []) if ("wo", o["id"], c) in ready]
            wait = max((c[0] for c in comps), default=today)
            duration = max(0, (o["due_date"] - o["start_date"]).days)
            end = max(o["due_date"], today, wait + datetime.timedelta(days=duration))
            ev = g.add("make", end, doc=f"OP-{o['number']}", item=item, qty=Decimal(o["q"]),
                       after=[e for c in comps for e in c[1]])
            made[o["id"]] = ev
            supplies.setdefault(item, []).append([end, Decimal(o["q"]), ev])
        give(supplies.get(item, []), demands.get(item, []), ready, g.end)

    # Deliveries, invoices (whole order), receivables by the payment term plus the customer's delay, taxes.
    costs = common.unit_costs(sorted({s["product_id"] for s in sales})) if sales else {}
    tax_day = int(value_or("financeiro.dia_impostos", TAX_DAY))
    tax_data = hooks.get("tax_data")
    line_cost = hooks.get("line_cost") or (lambda item, qty, at, cost: cost)
    burden = {}
    by_order = {}
    for s in sales:
        by_order.setdefault(s["id"], []).append(s)
    for oid, lines in by_order.items():
        head = lines[0]
        deliveries = []
        for s in lines:
            if s["kind"] == "goods":
                at, used = ready.get(("sale", oid, s["line"]), (g.end, []))
                risk = at > max(today, s["promised"])
                ev = g.add("delivery", max(at, today), doc=f"ORD-{head['number']}/{s['line']}", party=head["customer_id"],
                           item=s["product_id"], qty=Decimal(s["quantity"]), promised=s["promised"], at_risk=risk, after=used)
            else:
                ev = g.add("delivery", max(today, s["promised"]), doc=f"ORD-{head['number']}/{s['line']}",
                           party=head["customer_id"], item=s["product_id"], qty=Decimal(s["quantity"]), promised=s["promised"],
                           at_risk=False)
            deliveries.append(ev)
        total = sum((Decimal(s["amount"]) for s in lines), ZERO)
        inv_at = max(e["date"] for e in deliveries)
        line_costs = [money(line_cost(s["product_id"], Decimal(s["quantity"]), inv_at,
                                      Decimal(s["quantity"]) * costs.get(s["product_id"], ZERO))) for s in lines]
        inv = g.add("invoice", inv_at, total, doc=f"ORD-{head['number']}", party=head["customer_id"], after=deliveries,
                    cost=sum(line_costs, ZERO),
                    lines=[{"item": s["product_id"], "group": s["item_group"], "revenue": money(s["amount"]), "cost": c}
                           for s, c in zip(lines, line_costs)])
        try:
            term = terms.term_for(head["customer_id"], head["payment_term"])
        except ana.Error as e:
            term = None
            g.note(f"pedido {head['number']}: {e.message}")
        gross = terms.adjusted(total, term) if term else total
        sched = terms.schedule(gross, term, inv_at) if term else [(1, inv_at + datetime.timedelta(days=30), gross)]
        for n, due, amount in (sched if g.cash else []):
            due = due + datetime.timedelta(days=term_days["receive"])
            d = delay("receivable", head["customer_id"], cust_used, due)
            if d is None:
                g.note("há parcelas de pedidos que, neste cenário, não entram")
                continue
            g.add("cash_in", max(today, due + datetime.timedelta(days=d)), amount, doc=f"ORD-{head['number']} parcela {n}",
                  party=head["customer_id"], after=[inv], due=due)
        share = tax_share(burden, head["customer_id"], any(s["kind"] != "goods" for s in lines), g, inv_at.replace(day=1),
                          tax_data)
        if share:
            month = (inv_at.replace(day=1) + datetime.timedelta(days=32)).replace(day=1)
            g.add("cash_out", month.replace(day=min(tax_day, 28)), -(total * share), doc=f"impostos de ORD-{head['number']}",
                  party=None, after=[inv], tax=True)

    # 4. What leaves the bank every month without a bill (rent, payroll, fees), measured over the last months.
    rec = None if not cash else ana.sql_one(
        "SELECT COALESCE(sum(-s.amount), 0) AS out FROM finance.bank_statement_line s "
        "WHERE s.amount < 0 AND s.posted_on >= date_trunc('month', $1::date) - make_interval(months => $2) "
        "  AND s.posted_on < date_trunc('month', $1::date) "
        "  AND NOT EXISTS (SELECT 1 FROM finance.bank_match m WHERE m.line_id = s.id)", today, RECURRING_MONTHS)
    monthly = money(Decimal(rec["out"]) / RECURRING_MONTHS) if rec else ZERO
    if monthly > 0:
        m = today.replace(day=1)
        while m < g.end:
            at = m.replace(day=RECURRING_DAY)
            if at >= today:
                g.add("cash_out", at, -monthly, doc="saídas do banco sem título (média de 3 meses)", recurring=True)
            m = (m + datetime.timedelta(days=32)).replace(day=1)

    g.delays = ([{"kind": "cliente", "party": p, "days": d, "source": w} for p, (d, w) in sorted(cust_used.items())] +
                [{"kind": "fornecedor", "party": p, "days": d, "source": w} for p, (d, w) in sorted(supp_used.items())])
    return g


def give(supplies, demands, ready, never):
    """Supplies to demands by date, the oldest first. A demand is met on the date of the last supply it took (the
    events it waits for); one nothing covers is met `never` (the end of the horizon: at risk)."""
    sup = sorted(([d, q, e] for d, q, e in supplies), key=lambda x: (x[0], x[2]["id"] if x[2] else -1))
    i, left = 0, (sup[0][1] if sup else ZERO)
    for date, qty, key in sorted(demands, key=lambda x: (x[0], str(x[2]))):
        need, at, used = qty, None, []
        while need > 0 and i < len(sup):
            take = min(need, left)
            need -= take
            left -= take
            at = sup[i][0] if at is None else max(at, sup[i][0])
            if sup[i][2] is not None:
                used.append(sup[i][2])
            if left <= 0:
                i += 1
                left = sup[i][1] if i < len(sup) else ZERO
        ready[key] = ((never if need > 0 else (at or date)), used)


def tax_share(cache, customer, service, g, month, data=None):
    """The share of the revenue paid in taxes for this customer in the month of the invoice (spec 049, the engine's
    rules in force on that date — or a scenario's, `data`; never a typed rate)."""
    op = "service_sale" if service else "goods_sale"
    key = (op, customer, month)
    if key not in cache:
        from ana_lib.tax import engine
        try:
            cache[key] = engine.burden_rate({"operation": op, "recipient": customer, "date": month}, data=data)
        except engine.TaxError as e:
            cache[key] = ZERO
            g.note(f"impostos não estimados ({'serviços' if service else 'mercadorias'}): {e.message}")
    return cache[key]


def value_or(name, default):
    try:
        v = ana.value(name)
    except ana.Error:
        return default
    return default if v is None else v


# ------------------------------------------------------------------ reading the projection
def weekly(g, cash=True):
    """Per week: in, out, closing balance; the lowest position and its day; deliveries at risk; margin by item, line
    and customer — what the screen shows (plan §2)."""
    weeks = []
    start = g.today - datetime.timedelta(days=g.today.weekday())
    for k in range(g.horizon_weeks):
        weeks.append({"week": start + datetime.timedelta(weeks=k), "in": ZERO, "out": ZERO, "close": ZERO})
    daily = {}
    opening = ZERO
    for e in g.events:
        if e["kind"] == "bank_balance":
            opening += e["amount"]
        elif e["kind"] in ("cash_in", "cash_out") and e["date"] < g.end:
            daily[e["date"]] = daily.get(e["date"], ZERO) + e["amount"]
            w = (e["date"] - start).days // 7
            if 0 <= w < len(weeks):
                weeks[w]["in" if e["amount"] > 0 else "out"] += e["amount"]
    balance, low, low_day = opening, opening, g.today
    for day in sorted(daily):
        balance += daily[day]
        if balance < low:
            low, low_day = balance, day
    running = opening
    for w in weeks:
        running += w["in"] + w["out"]
        w["close"] = running
    result = {"items": {}, "groups": {}, "customers": {}}
    for e in g.events:
        if e["kind"] == "invoice" and e["date"] < g.end:
            for ln in e["lines"]:
                for dim, key in (("items", ln["item"]), ("groups", ln["group"] or "—"), ("customers", e["party"])):
                    acc = result[dim].setdefault(key, {"revenue": ZERO, "cost": ZERO})
                    acc["revenue"] += ln["revenue"]
                    acc["cost"] += ln["cost"]
    risk = [e for e in g.events if e["kind"] == "delivery" and e.get("at_risk")]
    out = {"as_of": g.today, "horizon_weeks": g.horizon_weeks, "notes": g.notes, "delays": g.delays,
           "deliveries_at_risk": [{"doc": e["doc"], "promised": e["promised"], "date": e["date"] if e["date"] < g.end else None}
                                  for e in risk],
           "result": {dim: [{"key": k, **v, "margin": v["revenue"] - v["cost"]} for k, v in sorted(m.items(), key=lambda kv: str(kv[0]))]
                      for dim, m in result.items()}}
    if cash:
        out.update({"opening": opening, "weeks": weeks, "lowest": {"balance": low, "date": low_day}})
    return out


# ------------------------------------------------------------------ correction, measured (RNF-069-03, plan §8)
def backtest(today=None, days=7):
    """The projection redone as of `days` ago — the bills open then, the delays measured until then — against what the
    bank really moved for those bills since. The deviation is shown with the base and becomes a metric."""
    today = today or datetime.date.today()
    as_of = today - datetime.timedelta(days=days)
    delays = Delays(as_of)
    predicted = actual = ZERO
    for r in ana.sql(
            "SELECT b.kind, b.party_id, b.due_date, b.amount, p.paid_on FROM finance.bill b "
            "LEFT JOIN LATERAL (SELECT min(s.posted_on) AS paid_on FROM finance.bank_match m "
            "  JOIN finance.bank_statement_line s ON s.id = m.line_id WHERE m.bill_id = b.id) p ON true "
            "WHERE b.issue_date <= $1 AND b.status <> 'cancelled' AND (p.paid_on IS NULL OR p.paid_on > $1) "
            "  AND (b.status = 'open' OR p.paid_on IS NOT NULL)", as_of):
        sign = 1 if r["kind"] == "receivable" else -1
        d = delays.of("receivable", r["party_id"])[0] if r["kind"] == "receivable" else 0
        when = max(as_of + datetime.timedelta(days=1), r["due_date"] + datetime.timedelta(days=d))
        if when <= today:
            predicted += sign * Decimal(r["amount"])
        if r["paid_on"] is not None and r["paid_on"] <= today:
            actual += sign * Decimal(r["amount"])
    base = max(abs(actual), abs(predicted), Decimal(1))
    return {"as_of": as_of, "until": today, "predicted": money(predicted), "actual": money(actual),
            "deviation_pct": float(((predicted - actual).copy_abs() / base * 100).quantize(Decimal("0.1")))}
