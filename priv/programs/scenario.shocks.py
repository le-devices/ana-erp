# ana:description Cenários: os choques (lista fechada, extensível por dado), validados e aplicados às fontes da projeção
# ana:kind library
"""Spec 069 (T-069-03, RF-069-02, D2; plan §3). A shock is data — {kind, params} — of a kind in scenario.shock_kind.
Each kind names a function of this library (REGISTRY: a new one is data plus a reviewed function, spec 064's gate).
Applying shocks never makes a parallel formula: they change the sources the base projection reads (hooks of
scenario.projection.build and production.mrp.compute) and, for company values and exchange rates, what `ana.value`
answers during the calculation. The rules of the ERP do the rest.

Combining scenarios is putting their shocks together; the order never changes the result: delays on the same party
take the largest, percentages multiply, term shifts add up, a date "a partir de" takes the earliest stop."""

import contextlib
import datetime
import json
import math
import re
from decimal import Decimal, ROUND_HALF_UP

import ana

ZERO = Decimal(0)
ONE = Decimal(1)
RATE_RE = re.compile(r"^financeiro\.cotacao_([a-z]{3})$")
MAX_SHOCKS = 30


def fail(n, msg):
    raise ana.Error("SCENARIO_SHOCK", f"choque {n}: {msg}" if n else msg)


def as_date(v):
    if v is None or v == "":
        return None
    if isinstance(v, datetime.datetime):
        return v.date()
    if isinstance(v, datetime.date):
        return v
    try:
        return datetime.date.fromisoformat(str(v)[:10])
    except ValueError:
        return False


def br(d):
    return f"{d:%d/%m/%Y}"


def pct_text(p):
    p = Decimal(p)
    return f"{'+' if p > 0 else ''}{p.normalize():f}%".replace(".", ",")


# ------------------------------------------------------------------ the catalog
def catalog():
    """The kinds of shock in use, in the order of the screen."""
    rows = ana.sql("SELECT code, name, description, params, function FROM scenario.shock_kind WHERE active ORDER BY sequence, code")
    for r in rows:
        if isinstance(r["params"], str):
            r["params"] = json.loads(r["params"])
    return rows


# ------------------------------------------------------------------ validation
def validate(shocks):
    """The shocks checked against the catalog, with their values typed and a sentence for each one:
    [{kind, params, label}]. Refuses (SCENARIO_SHOCK) an unknown kind or parameter, a missing one, a value of the
    wrong type and a reference that does not exist — saying which shock and why."""
    if shocks is None:
        return []
    if not isinstance(shocks, list):
        fail(None, "os choques vêm numa lista")
    if len(shocks) > MAX_SHOCKS:
        fail(None, f"no máximo {MAX_SHOCKS} choques por cenário")
    kinds = {k["code"]: k for k in catalog()}
    out = []
    refs = {"party": set(), "item": set(), "group": set(), "resource": set(), "tax_rule": set()}
    for n, s in enumerate(shocks, 1):
        if not isinstance(s, dict) or not isinstance(s.get("params", {}), dict):
            fail(n, "cada choque é {kind, params}")
        k = kinds.get(s.get("kind"))
        if not k:
            fail(n, f"tipo desconhecido: {s.get('kind')!r} (os tipos estão em Cenários → choques)")
        if k["function"] not in REGISTRY:
            fail(n, f"o tipo {k['code']} não tem função revisada na biblioteca de choques")
        given = {key: v for key, v in (s.get("params") or {}).items() if v not in (None, "")}
        spec = {p["name"]: p for p in k["params"]}
        unknown = sorted(set(given) - set(spec))
        if unknown:
            fail(n, f"{k['name']}: parâmetro desconhecido {', '.join(unknown)}")
        params = {}
        for name, p in spec.items():
            if name not in given:
                if p.get("required"):
                    fail(n, f"{k['name']}: falta {p['label']}")
                continue
            params[name] = typed(n, k["name"], p, given[name], refs)
        out.append({"kind": k["code"], "params": params, "n": n, "_k": k})
    names = resolve(refs)
    for s in out:
        n, k, p = s.pop("n"), s.pop("_k"), s["params"]
        check_kind(n, k, p, names)
        s["label"] = label(k, p, names)
    return out


def typed(n, kname, p, v, refs):
    t, lab = p["type"], p["label"]
    try:
        if t == "currency":
            c = str(v).strip().upper()
            if not re.fullmatch(r"[A-Z]{3}", c) or c == "BRL":
                fail(n, f"{kname}: {lab} deve ser uma moeda estrangeira (USD, EUR…)")
            return c
        if t == "percent":
            d = Decimal(str(v).replace(",", "."))
            if not (Decimal(-100) < d <= Decimal(1000)):
                fail(n, f"{kname}: {lab} fora do intervalo (acima de −100% e até 1000%)")
            return str(d)
        if t == "date":
            d = as_date(v)
            if d is False:
                fail(n, f"{kname}: {lab} não é uma data (AAAA-MM-DD)")
            return d.isoformat()
        if t == "days":
            d = int(v)
            if not -365 <= d <= 365:
                fail(n, f"{kname}: {lab} entre −365 e 365")
            return d
        if t in ("supplier", "customer"):
            i = int(v)
            refs["party"].add(i)
            return i
        if t == "item":
            refs["item"].add(str(v).strip())
            return str(v).strip()
        if t == "group":
            g = str(v).strip().upper()
            refs["group"].add(g)
            return g
        if t == "resource":
            r = str(v).strip().upper()
            refs["resource"].add(r)
            return r
        if t == "tax_rule":
            i = int(v)
            refs["tax_rule"].add(i)
            return i
        if t == "value_name":
            name = str(v).strip()
            try:
                ana.value(name)
            except ana.Error:
                fail(n, f"{kname}: o valor da empresa {name} não existe")
            return name
        if t == "value":
            return v if isinstance(v, (str, int, bool, list)) else str(v)
        if t == "choice":
            keys = [c[0] for c in p.get("choices", [])]
            if v not in keys:
                fail(n, f"{kname}: {lab} deve ser um de {', '.join(keys)}")
            return v
    except (ValueError, ArithmeticError, TypeError):
        fail(n, f"{kname}: {lab} inválido ({v!r})")
    fail(n, f"{kname}: tipo de parâmetro sem tratamento ({t})")


def resolve(refs):
    """One query per kind of reference: names for the sentences, and what does not exist."""
    names = {"party": {}, "item": {}, "group": set(), "resource": {}, "tax_rule": {}}
    if refs["party"]:
        names["party"] = {r["id"]: r for r in ana.sql("SELECT id, name, kind FROM base.party WHERE id = ANY($1)",
                                                      sorted(refs["party"]))}
    if refs["item"]:
        codes = sorted(refs["item"])
        names["item"] = {r["code"]: r for r in ana.sql(
            "SELECT id, code, name FROM base.product WHERE code = ANY($1) OR id::text = ANY($1)", codes)}
        names["item"].update({str(r["id"]): r for r in list(names["item"].values())})
    if refs["group"]:
        names["group"] = {r["g"] for r in ana.sql("SELECT DISTINCT item_group AS g FROM base.product WHERE item_group = ANY($1)",
                                                  sorted(refs["group"]))}
    if refs["resource"]:
        names["resource"] = {r["code"]: r for r in ana.sql("SELECT code, name FROM production.resource WHERE code = ANY($1)",
                                                           sorted(refs["resource"]))}
    if refs["tax_rule"]:
        names["tax_rule"] = {r["id"]: r for r in ana.sql("SELECT id, name, status, tax FROM tax.rule WHERE id = ANY($1)",
                                                         sorted(refs["tax_rule"]))}
    return names


def check_kind(n, k, p, names):
    name = k["name"]
    for key, kind in (("supplier", "fornecedor"), ("customer", "cliente")):
        if key in p:
            party = names["party"].get(p[key])
            if not party:
                fail(n, f"{name}: {kind} {p[key]} não existe")
            if key == "supplier" and party["kind"] == "customer":
                fail(n, f"{name}: {party['name']} não é fornecedor")
            if key == "customer" and party["kind"] == "supplier":
                fail(n, f"{name}: {party['name']} não é cliente")
    if "item" in p:
        it = names["item"].get(p["item"])
        if not it:
            fail(n, f"{name}: item {p['item']} não existe")
        p["item"] = it["code"]
    if "group" in p and p["group"] not in names["group"]:
        fail(n, f"{name}: nenhum item no grupo {p['group']}")
    if "resource" in p and p["resource"] not in names["resource"]:
        fail(n, f"{name}: recurso {p['resource']} não existe")
    if "rule" in p:
        r = names["tax_rule"].get(p["rule"])
        if not r:
            fail(n, f"{name}: regra {p['rule']} não existe")
        if r["status"] != "draft":
            fail(n, f"{name}: a regra {p['rule']} não está em rascunho (só um rascunho entra num cenário)")
    targets = [x for x in ("item", "group", "customer") if x in p]
    if k["code"] == "purchase_price" and len([x for x in targets if x != "customer"]) != 1:
        fail(n, f"{name}: informe um item ou um grupo (um dos dois)")
    if k["code"] == "sales_volume" and len(targets) != 1:
        fail(n, f"{name}: informe um item, um grupo ou um cliente (um só)")
    if k["code"] == "capacity":
        if not Decimal(0) < Decimal(p["pct"]) <= Decimal(100):
            fail(n, f"{name}: a queda vai de 1% a 100% (parado)")
        if p.get("from") and p["from"] > p["until"]:
            fail(n, f"{name}: o fim vem antes do início")


def label(k, p, names):
    """The shock as a sentence: what the screen, the comparison and the assistant show."""
    def party(i):
        return names["party"][i]["name"]

    since = f" a partir de {br(as_date(p['from']))}" if p.get("from") else ""
    code = k["code"]
    if code == "currency":
        return f"{p['currency']} {pct_text(p['pct'])}{since}"
    if code == "purchase_price":
        what = f"item {p['item']}" if "item" in p else f"grupo {p['group']}"
        return f"preço de compra do {what} {pct_text(p['pct'])}{since}"
    if code == "supplier_delay":
        return f"{party(p['supplier'])} entrega {p['days']} dias depois"
    if code == "supplier_stops":
        return f"{party(p['supplier'])} deixa de entregar{since}"
    if code == "customer_delay":
        return f"{party(p['customer'])} paga {p['days']} dias depois"
    if code == "customer_stops":
        return f"{party(p['customer'])} deixa de pagar{since}"
    if code == "payment_terms":
        side = "recebimento" if p["side"] == "receive" else "pagamento"
        return f"prazo de {side} {'+' if p['days'] > 0 else ''}{p['days']} dias"
    if code == "sales_volume":
        what = (f"do item {p['item']}" if "item" in p else f"do grupo {p['group']}" if "group" in p
                else f"de {party(p['customer'])}")
        return f"vendas {what} {pct_text(p['pct'])}"
    if code == "capacity":
        r = names["resource"][p["resource"]]["name"]
        stop = "parado" if Decimal(p["pct"]) >= 100 else f"com {pct_text(-Decimal(p['pct']))} de capacidade"
        start = f" de {br(as_date(p['from']))}" if p.get("from") else ""
        return f"{r} {stop}{start} até {br(as_date(p['until']))}"
    if code == "tax_rule":
        return f"regra de imposto {names['tax_rule'][p['rule']]['name']} em vigor{since}"
    if code == "company_value":
        return f"{p['name']} = {p['value']}{since}"
    return k["name"]


# ------------------------------------------------------------------ effects: what the shocks change
class Effects:
    """Shocks gathered, order-free (module docstring)."""

    def __init__(self, today):
        self.today = today
        self.supplier_extra, self.customer_extra = {}, {}
        self.supplier_stop, self.customer_stop = {}, {}
        self.terms = {"receive": 0, "pay": 0}
        self.rate = {}                      # currency -> [(from, factor)]
        self.values = {}                    # name -> [(from, value)]
        self.price = []                     # [(item code, group, from, factor)]
        self.volume = []                    # [(item code, group, customer, factor)]
        self.capacity = []                  # [(resource, pct, from, until)]
        self.drafts = []                    # [(rule id, from)]
        self.original = None                # ana.value without the scenario, while applied

    def since(self, p):
        return as_date(p.get("from")) or self.today


def _currency(e, p):
    e.rate.setdefault(p["currency"], []).append((e.since(p), ONE + Decimal(p["pct"]) / 100))


def _purchase_price(e, p):
    e.price.append((p.get("item"), p.get("group"), e.since(p), ONE + Decimal(p["pct"]) / 100))


def _supplier_delay(e, p):
    e.supplier_extra[p["supplier"]] = max(e.supplier_extra.get(p["supplier"], p["days"]), p["days"])


def _supplier_stops(e, p):
    e.supplier_stop[p["supplier"]] = min(e.supplier_stop.get(p["supplier"], e.since(p)), e.since(p))


def _customer_delay(e, p):
    e.customer_extra[p["customer"]] = max(e.customer_extra.get(p["customer"], p["days"]), p["days"])


def _customer_stops(e, p):
    e.customer_stop[p["customer"]] = min(e.customer_stop.get(p["customer"], e.since(p)), e.since(p))


def _payment_terms(e, p):
    e.terms[p["side"]] += p["days"]


def _sales_volume(e, p):
    e.volume.append((p.get("item"), p.get("group"), p.get("customer"), ONE + Decimal(p["pct"]) / 100))


def _capacity(e, p):
    e.capacity.append((p["resource"], Decimal(p["pct"]), as_date(p.get("from")) or e.today, as_date(p["until"])))


def _tax_rule(e, p):
    e.drafts.append((p["rule"], as_date(p.get("from")) or e.today))


def _company_value(e, p):
    e.values.setdefault(p["name"], []).append((e.since(p), p["value"]))


REGISTRY = {"currency": _currency, "purchase_price": _purchase_price, "supplier_delay": _supplier_delay,
            "supplier_stops": _supplier_stops, "customer_delay": _customer_delay, "customer_stops": _customer_stops,
            "payment_terms": _payment_terms, "sales_volume": _sales_volume, "capacity": _capacity, "tax_rule": _tax_rule,
            "company_value": _company_value}


def effects(shocks, today=None):
    """Validated shocks → Effects (the function of each kind, from the catalog)."""
    e = Effects(today or datetime.date.today())
    funcs = {k["code"]: k["function"] for k in catalog()}
    for s in shocks:
        REGISTRY[funcs[s["kind"]]](e, s["params"])
    return e


# ------------------------------------------------------------------ applying: hooks and company values
@contextlib.contextmanager
def applied(e):
    """While the projection runs: company values and exchange rates as the scenario says (only in memory, only in
    this execution). Everything that reads them — currency.rate, the tax engine, the projection — sees the scenario."""
    if not e.values and not e.rate:
        yield
        return
    original = e.original = ana.value

    def value(name, at=None, company=None):
        day = as_date(at) or e.today
        overrides = sorted(e.values.get(name, []), key=lambda x: x[0])
        try:
            v = original(name, at=at, company=company)
        except ana.Error as err:
            if err.code != "VALUE_NOT_FOUND" or not overrides:
                raise
            v = None
        for since, content in overrides:
            if day >= since:
                v = typed_like(v, content)
        m = RATE_RE.match(name)
        if m and v is not None:
            for since, factor in e.rate.get(m.group(1).upper(), []):
                if day >= since:
                    v = Decimal(str(v)) * factor
        return v

    ana.value = value
    try:
        yield
    finally:
        ana.value = original


def typed_like(base, content):
    """The scenario's content in the type of the value in force (an integer stays an integer)."""
    if base is None or isinstance(content, type(base)):
        return content
    if isinstance(base, bool):
        return str(content).lower() in ("true", "sim", "1", "yes")
    if isinstance(base, int):
        return int(content)
    if isinstance(base, Decimal):
        return Decimal(str(content).replace(",", "."))
    if isinstance(base, datetime.date):
        return as_date(content)
    return content


def hooks(e):
    """The hooks of scenario.projection.build for these effects (nothing for a scenario without shocks)."""
    h = {}
    products = {}
    if e.price or e.volume:
        codes = sorted({x[0] for x in e.price + e.volume if x[0]})
        groups = sorted({x[1] for x in e.price + e.volume if x[1]})
        products = {r["id"]: r for r in ana.sql("SELECT id, code, item_group FROM base.product "
                                                "WHERE code = ANY($1) OR item_group = ANY($2)", codes, groups)}

    def factor_price(item, at):
        f = ONE
        prod = products.get(item) or {}
        for code, group, since, k in e.price:
            if at >= since and ((code and prod.get("code") == code) or (group and prod.get("item_group") == group)):
                f *= k
        return f

    def factor_volume(item, customer, with_customer=True):
        f = ONE
        prod = products.get(item) or {}
        for code, group, cust, k in e.volume:
            if (code and prod.get("code") == code) or (group and prod.get("item_group") == group) \
                    or (with_customer and cust and cust == customer):
                f *= k
        return f

    if e.supplier_extra or e.supplier_stop or e.customer_extra or e.customer_stop:
        def delay(kind, party, days, at):
            extra, stop = ((e.supplier_extra, e.supplier_stop) if kind == "supplier"
                           else (e.customer_extra, e.customer_stop))
            if party in stop and (at is None or at >= stop[party]):
                return None
            return days + extra.get(party, 0)
        h["delay"] = delay

        def purchases(rows):
            out = []
            for r in rows:
                s = r["supplier_id"]
                if s in e.supplier_stop and r["d"] >= e.supplier_stop[s]:
                    continue
                out.append({**r, "d": r["d"] + datetime.timedelta(days=e.supplier_extra.get(s, 0))} if s in e.supplier_extra else r)
            return out
        h.setdefault("mrp", {})["purchases"] = purchases

    if e.terms["receive"] or e.terms["pay"]:
        h["term_days"] = dict(e.terms)

    if e.price:
        h["price"] = lambda item, price, at: price * factor_price(item, at)

    if e.volume:
        def scale(r, q, amount=None):
            f = factor_volume(r["product_id"], r.get("customer_id"))
            if f == ONE:
                return r
            r = dict(r)
            r[q] = Decimal(r[q]) * f
            if amount:
                r[amount] = (Decimal(r[amount]) * f).quantize(Decimal("0.01"), ROUND_HALF_UP)
            return r

        h["sale_lines"] = lambda rows: [scale(r, "quantity", "amount") for r in rows]
        h.setdefault("mrp", {})["sales"] = lambda rows: [scale(r, "q") for r in rows]

        def forecast(rows):
            out = []
            for r in rows:
                f = factor_volume(r["product_id"], None, with_customer=False)
                out.append(r if f == ONE else {**r, "quantity": Decimal(r["quantity"]) * f})
            return out
        h["mrp"]["forecast"] = forecast

    if e.price or e.rate:
        h["line_cost"] = line_cost(e, factor_price)

        def unit_costs(ids):
            """The ERP's cost, read with the company values as they are (the scenario's rates come in line_cost)."""
            from ana_lib.production import common
            current = ana.value
            ana.value = e.original or current
            try:
                return common.unit_costs(ids)
            finally:
                ana.value = current
        h["unit_costs"] = unit_costs

    if e.capacity:
        h["work_orders"] = work_orders(e)

    if e.drafts:
        from ana_lib.tax import engine
        h["tax_data"] = engine.with_drafts(e.drafts)
    return h


def line_cost(e, factor_price):
    """The cost of an order line invoiced at `at`: the base cost plus how much the shocked prices and rates change
    the purchased components it is made of (through the active structures, to the purchased leaves)."""
    from ana_lib.finance import currency
    from ana_lib.production import common
    structures = common.active_structures([r["product_id"] for r in ana.sql(
        "SELECT product_id FROM production.structure WHERE active")])
    bought = {r["product_id"]: r for r in ana.sql(
        "SELECT product_id, price, currency FROM supply.supplier_item WHERE preferred AND price IS NOT NULL")}
    leaves = {}

    def exposure(item, depth=0):
        """[(component, quantity per unit, price, currency)]: what is bought to make one unit of `item`."""
        if item in leaves:
            return leaves[item]
        lines = structures.get(item) if depth < 50 else None
        if lines:
            out = []
            for ln in lines:
                per = Decimal(ln["quantity"]) * (ONE + Decimal(ln["scrap_pct"] or 0) / 100)
                out += [(c, per * q, p, cur) for c, q, p, cur in exposure(ln["component_id"], depth + 1)]
        else:
            r = bought.get(item)
            out = [(item, ONE, Decimal(r["price"]), r["currency"])] if r else []
        leaves[item] = out
        return out

    cache = {}

    def rates(cur, at):
        # (rate without the scenario, rate with it): a rate shock is a factor over the rate in force, so the base is
        # the scenario's rate divided by its factors.
        if (cur, at) not in cache:
            try:
                shocked = currency.rate(cur, at)
            except ana.Error:
                cache[(cur, at)] = None
                return None
            f = ONE
            for since, k in e.rate.get((cur or "BRL").upper(), []):
                if at >= since:
                    f *= k
            cache[(cur, at)] = (shocked / f, shocked)
        return cache[(cur, at)]

    def cost(item, qty, at, base):
        delta = ZERO
        for comp, per, price, cur in exposure(item):
            r = rates(cur, at)
            if r is None:
                continue
            delta += per * (price * factor_price(comp, at) * r[1] - price * r[0])
        return base + qty * delta

    return cost


def work_orders(e):
    """Production orders when a resource produces less: the hours each order needs on it (routing) take longer —
    or, stopped, the order waits for the resource to come back."""
    def apply(rows):
        rows = list(rows)
        if not rows:
            return rows
        res = {c[0] for c in e.capacity}
        load = {}
        for r in ana.sql(
                "SELECT o.id, op.resource_code AS res, sum(op.setup_min + op.run_min * (o.quantity - o.good_qty - o.scrap_qty)) / 60.0 "
                "  / NULLIF(max(rs.daily_hours * rs.efficiency_pct / 100), 0) AS days "
                "FROM production.work_order o JOIN production.routing rt ON rt.product_id = o.product_id AND rt.active "
                "JOIN production.operation op ON op.routing_id = rt.id JOIN production.resource rs ON rs.code = op.resource_code "
                "WHERE o.id = ANY($1) AND op.resource_code = ANY($2) GROUP BY 1, 2", [r["id"] for r in rows], sorted(res)):
            load[(r["id"], r["res"])] = Decimal(r["days"] or 0)
        out = []
        for r in rows:
            r = dict(r)
            for resource, pct, since, until in e.capacity:
                days = load.get((r["id"], resource))
                if days is None or r["due_date"] < since or r["start_date"] > until:
                    continue
                span = r["due_date"] - r["start_date"]
                if pct >= 100:
                    start = max(r["start_date"], until + datetime.timedelta(days=1))
                    r["start_date"], r["due_date"] = start, start + span
                else:
                    extra = math.ceil(days * pct / (100 - pct))
                    r["due_date"] = r["due_date"] + datetime.timedelta(days=extra)
            out.append(r)
        return out
    return apply


# ------------------------------------------------------------------ one call: a scenario's projection
def project(shocks, horizon_weeks=26, today=None, cash=True):
    """The projection with these (validated) shocks: the same build as the base, fed by the shocked sources."""
    from ana_lib.scenario import projection
    e = effects(shocks, today)
    with applied(e):
        return projection.build(horizon_weeks, today=today, hooks=hooks(e), cash=cash)
