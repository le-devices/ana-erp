# ana:description Motor de impostos: escolhe as regras vigentes e calcula tributos de qualquer documento, com explicação
# ana:kind library
"""Tax engine (spec 049, D1–D3, D11, RF-049-01, RF-049-11, RNF-049-01/02/05).

The engine knows only generic mechanisms (P21): fiscal attributes with validity, code lists, tables with
validity, progressive brackets, indicators summed from the accounts, closed formulas and accounting roles.
No tax, regime or rate is named here: all of it is data (`tax.*` tables), delivered in rule packages.

    from ana_lib.tax import engine
    r = engine.calculate({"operation": "service_sale", "date": "2026-11-19", "recipient": 12,
                          "contract": "P-001", "items": [{"description": "Horas", "quantity": 10,
                          "unit_price": "150.00"}]}, record=("project_invoice", "123"))

`compute()` is pure (no database): the runtime tests drive it with in-memory data.
"""

import datetime
import hashlib
import json
import unicodedata
from decimal import Decimal, ROUND_HALF_UP

from ana_lib.tax import formula as fx

CENT = Decimal("0.01")
MONEY = ("base", "amount", "withheld", "credit")
ENTITIES = ("company", "party", "item", "contract")
REGISTRY_FIELDS = {          # registry columns every document carries (not tax law: identity and address)
    "company": ("id", "tax_id", "city", "state", "country", "person_kind"),
    "party": ("id", "name", "tax_id", "city", "state", "country", "person_kind", "kind"),
    "contract": ("code", "customer_id"),
    "item": ("code",),
}


class TaxError(Exception):
    def __init__(self, code, message, detail=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.detail = detail or {}


# --------------------------------------------------------------------------- helpers

def norm_text(v):
    """Comparable text: no accents, lower case, single spaces ("São  Paulo" → "sao paulo")."""
    if v is None:
        return None
    s = unicodedata.normalize("NFKD", str(v))
    s = "".join(c for c in s if not unicodedata.combining(c))
    return " ".join(s.lower().split())


def as_date(v):
    if v is None:
        return datetime.date.today()
    if isinstance(v, datetime.datetime):
        return v.date()
    if isinstance(v, datetime.date):
        return v
    return datetime.date.fromisoformat(str(v)[:10])


def valid_on(row, day):
    f, t = row.get("valid_from"), row.get("valid_to")
    return (f is None or as_date(f) <= day) and (t is None or day <= as_date(t))


def _json(v):
    return json.loads(v) if isinstance(v, str) else (v if v is not None else {})


def money(v):
    return fx.dec(v).quantize(CENT, rounding=ROUND_HALF_UP)


def canonical(obj):
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"), default=str)


# --------------------------------------------------------------------------- criteria and specificity

def criteria_match(criteria, env):
    for path, want in (criteria or {}).items():
        have = env.get(path)
        if isinstance(want, dict) and "prefix" in want:
            prefixes = want["prefix"] if isinstance(want["prefix"], list) else [want["prefix"]]
            if have is None or not any(str(have).startswith(str(p)) for p in prefixes):
                return False
        elif isinstance(want, list):
            if not any(_same(have, w) for w in want):
                return False
        elif not _same(have, want):
            return False
    return True


def _same(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b or (isinstance(a, bool) and isinstance(b, bool) and a == b) or str(a).lower() == str(b).lower()
    if a is None or b is None:
        return a is None and b is None
    try:
        return fx.dec(a) == fx.dec(b)
    except fx.FormulaError:
        return norm_text(a) == norm_text(b)


def specificity(criteria):
    n, plen = 0, 0
    for want in (criteria or {}).values():
        n += 1
        if isinstance(want, dict) and "prefix" in want:
            ps = want["prefix"] if isinstance(want["prefix"], list) else [want["prefix"]]
            plen += min(len(str(p)) for p in ps)
    return (n, plen)


def _values(want):
    if isinstance(want, dict) and "prefix" in want:
        return None                      # prefixes: treated as possibly overlapping
    return want if isinstance(want, list) else [want]


def compatible(c1, c2):
    """True when some document could match both criteria sets (used to find conflicts)."""
    for path in set(c1 or {}) & set(c2 or {}):
        a, b = c1[path], c2[path]
        if isinstance(a, dict) and isinstance(b, dict) and "prefix" in a and "prefix" in b:
            pa = a["prefix"] if isinstance(a["prefix"], list) else [a["prefix"]]
            pb = b["prefix"] if isinstance(b["prefix"], list) else [b["prefix"]]
            if not any(str(x).startswith(str(y)) or str(y).startswith(str(x)) for x in pa for y in pb):
                return False
            continue
        va, vb = _values(a), _values(b)
        if va is None or vb is None:
            vals, pref = (vb, a) if va is None else (va, b)
            ps = pref["prefix"] if isinstance(pref["prefix"], list) else [pref["prefix"]]
            if not any(str(v).startswith(str(p)) for v in vals for p in ps):
                return False
            continue
        if not any(_same(x, y) for x in va for y in vb):
            return False
    return True


def overlaps(r1, r2):
    f1, t1 = as_date(r1.get("valid_from") or "0001-01-01"), as_date(r1.get("valid_to") or "9999-12-31")
    f2, t2 = as_date(r2.get("valid_from") or "0001-01-01"), as_date(r2.get("valid_to") or "9999-12-31")
    return f1 <= t2 and f2 <= t1


def conflicts(rule, others):
    """Active rules of the same tax that tie with `rule` for some document (CA-049-03)."""
    spec = specificity(rule.get("criteria"))
    return [o for o in others
            if o.get("id") != rule.get("id") and o["tax"] == rule["tax"] and o.get("status") == "active"
            and overlaps(rule, o) and specificity(o.get("criteria")) == spec
            and compatible(rule.get("criteria"), o.get("criteria"))]


def choose(rules, env, day):
    cands = [r for r in rules if r.get("status") == "active" and valid_on(r, day) and criteria_match(r.get("criteria"), env)]
    if not cands:
        return None
    cands.sort(key=lambda r: specificity(r.get("criteria")), reverse=True)
    best = specificity(cands[0].get("criteria"))
    tied = [r for r in cands if specificity(r.get("criteria")) == best]
    if len(tied) > 1:
        raise TaxError("TAX_RULE_CONFLICT",
                       "regras igualmente específicas para o mesmo caso: " + "; ".join(f"{r['id']} {r['name']}" for r in tied),
                       {"rules": [{"id": r["id"], "name": r["name"]} for r in tied]})
    return cands[0]


# --------------------------------------------------------------------------- data access (generic)

class Data:
    """Everything the engine reads, as plain data. `load()` fills it from the database; tests build it by hand."""

    def __init__(self, taxes=(), rules=(), tables=(), attributes=(), values=(), indicators=(), version=0):
        self.taxes = sorted(taxes, key=lambda t: (t.get("sequence", 100), t["code"]))
        self.rules = list(rules)
        self.tables = list(tables)
        self.attributes = list(attributes)
        self.values = list(values)
        self.indicators = {i["code"]: i for i in indicators}
        self.version = version
        self._compiled = {}
        self._by_tax = {}
        for r in self.rules:
            self._by_tax.setdefault(r["tax"], []).append(r)

    def rules_of(self, tax):
        return self._by_tax.get(tax, [])

    def compiled(self, rule):
        key = (rule["id"], rule.get("version"))
        c = self._compiled.get(key)
        if c is None:
            c = fx.validate([list(f) for f in rule["formulas"]])
            self._compiled[key] = c
        return c

    def table(self, name, key, day, field=None):
        rows = [t for t in self.tables if t["table_name"] == name and str(t["key"]) == str(key) and valid_on(t, day)]
        if not rows:
            raise fx.FormulaError(f"tabela {name} sem a chave {key} em {day:%d/%m/%Y}")
        return _field(rows[0], field)

    def bracket(self, name, group, value, field, day):
        value = fx.dec(value)
        rows = sorted((t for t in self.tables if t["table_name"] == name and str(t["key"]).split("/")[0] == str(group)
                       and valid_on(t, day)), key=lambda t: fx.dec(t["value"]))
        for t in rows:
            if value <= fx.dec(t["value"]):
                return _field(t, field)
        raise fx.FormulaError(f"faixa de {name}/{group} não encontrada para {value} em {day:%d/%m/%Y}")


def _field(row, field):
    if field in (None, "value"):
        return fx.dec(row["value"]) if row.get("value") is not None else None
    data = _json(row.get("data"))
    if field not in data:
        raise fx.FormulaError(f"tabela {row['table_name']} sem o campo {field}")
    v = data[field]
    return fx.dec(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else (fx.dec(v) if _numeric_text(v) else v)


def _numeric_text(v):
    if not isinstance(v, str):
        return False
    try:
        Decimal(v)
        return True
    except Exception:  # noqa: BLE001
        return False


def attributes_of(data, entity, ident, registry_row, day, explicit=None):
    """Registry fields + attribute sources + attribute values valid on `day` + explicit values (document)."""
    out = {}
    row = registry_row or {}
    for f in REGISTRY_FIELDS.get(entity, ()):
        if f in row:
            out[f] = row[f]
    if "state" in out:
        out["uf"] = out["state"]
    for a in data.attributes:
        if a["entity"] == entity and a.get("source") and a["source"] in row:
            out[a["code"]] = row[a["source"]]
    for v in data.values:
        if v["entity"] == entity and str(v["entity_id"]) == str(ident) and valid_on(v, day):
            out[v["attribute"]] = _typed(data, entity, v["attribute"], v["value"])
    for k, v in (explicit or {}).items():
        out[k] = v
    if out.get("city") is not None:
        out["city"] = norm_text(out["city"])
    if out.get("uf") is not None:
        out["uf"] = str(out["uf"]).upper()
    return out


def _typed(data, entity, code, value):
    kind = next((a.get("value_type") for a in data.attributes if a["entity"] == entity and a["code"] == code), "text")
    if value is None:
        return None
    if kind == "number":
        return fx.dec(value)
    if kind == "boolean":
        return str(value).lower() in ("true", "1", "yes", "sim")
    return value


# --------------------------------------------------------------------------- computation (pure)

def _env(prefix, attrs):
    return {f"{prefix}.{k}": v for k, v in attrs.items()}


def compute(doc, data, indicator=None):
    """doc: normalized document (see normalize()). Returns the result with explanation. Pure function."""
    day = as_date(doc["date"])
    base_env = {}
    base_env.update(_env("doc", doc.get("doc", {})))
    base_env.update(_env("emitter", doc.get("emitter", {})))
    base_env.update(_env("recipient", doc.get("recipient", {})))
    base_env.update(_env("contract", doc.get("contract", {})))
    e, r = doc.get("emitter", {}), doc.get("recipient", {})
    base_env["doc.same_city"] = bool(e.get("city") and e.get("city") == r.get("city") and e.get("uf") == r.get("uf"))
    base_env["doc.same_uf"] = bool(e.get("uf") and e.get("uf") == r.get("uf"))
    items = doc.get("items", [])
    total = sum((fx.dec(i["amount"]) for i in items), Decimal(0))
    base_env["doc.total"] = total
    base_env["total"] = total

    memo = {}

    def ind(code):
        if code not in memo:
            if indicator is None:
                raise fx.FormulaError(f"indicador indisponível: {code}")
            memo[code] = fx.dec(indicator(code))
        return memo[code]

    doc_results = {}                     # tax → accumulated document result
    item_results = [dict() for _ in items]
    explanation, used = [], {}

    def run_rule(rule, env, item_index):
        current = item_results[item_index] if item_index is not None else {}

        def tax_value(code, field):
            src = current.get(code) or doc_results.get(code)
            if src is None:
                return Decimal(0) if field in MONEY or field == "rate" else None
            v = src.get(field, (src.get("outputs") or {}).get(field))
            return Decimal(0) if v is None and field in MONEY else v
        funcs = {
            "table": lambda name, key, field=None: data.table(name, key, day, field),
            "bracket": lambda name, group, value, field: data.bracket(name, group, value, field, day),
            "indicator": ind,
            "tax": tax_value,
        }
        try:
            values = fx.evaluate(data.compiled(rule), env, funcs)
        except fx.FormulaError as err:
            raise TaxError("TAX_FORMULA", f"regra {rule['id']} ({rule['name']}): {err.text()}",
                           {"rule": rule["id"], "formula": err.formula}) from None
        used[rule["id"]] = rule.get("version")
        if "applies" in values and not values["applies"]:
            return None
        out = {"rule_id": rule["id"], "rule": rule["name"]}
        for k in MONEY:
            if values.get(k) is not None:
                out[k] = money(values[k])
        if values.get("rate") is not None:
            out["rate"] = fx.dec(values["rate"])
        extra = {k: v for k, v in values.items() if k not in MONEY and k not in ("rate", "applies")}
        explanation.append({"tax": rule["tax"], "item": item_index, "rule_id": rule["id"], "rule": rule["name"],
                            "criteria": rule.get("criteria") or {}, "values": {k: _plain(v) for k, v in values.items()}})
        out["outputs"] = {k: _plain(v) for k, v in extra.items()}
        return out

    for t in data.taxes:
        rules = data.rules_of(t["code"])
        if not rules:
            continue
        if t.get("scope", "item") == "document":
            env = dict(base_env)
            env.update({"amount": total, "quantity": Decimal(1), "unit_price": total, "discount": Decimal(0)})
            rule = choose(rules, env, day)
            if rule:
                res = run_rule(rule, env, None)
                if res:
                    doc_results[t["code"]] = {**res, "tax": t["code"], "name": t["name"]}
            continue
        for i, it in enumerate(items):
            env = dict(base_env)
            env.update(_env("item", it.get("attributes", {})))
            for k in ("amount", "quantity", "unit_price", "discount"):
                v = fx.dec(it.get(k) or 0)
                env[k] = v
                env[f"item.{k}"] = v
            rule = choose(rules, env, day)
            if not rule:
                continue
            res = run_rule(rule, env, i)
            if not res:
                continue
            item_results[i][t["code"]] = res
            acc = doc_results.setdefault(t["code"], {"tax": t["code"], "name": t["name"], "rules": []})
            for k in MONEY:
                if k in res:
                    acc[k] = acc.get(k, Decimal(0)) + res[k]
            if "rate" in res:
                acc.setdefault("rate", res["rate"])
            if res["rule_id"] not in acc["rules"]:
                acc["rules"].append(res["rule_id"])

    taxes = [doc_results[t["code"]] for t in data.taxes if t["code"] in doc_results]
    tot = {k: sum((x.get(k, Decimal(0)) for x in taxes), Decimal(0)) for k in ("amount", "withheld", "credit")}
    return {
        "date": day.isoformat(), "total": money(total), "taxes": taxes,
        "items": [{"index": i, "taxes": [{"tax": k, **v} for k, v in res.items()]} for i, res in enumerate(item_results)],
        "totals": {k: money(v) for k, v in tot.items()},
        "net": money(total - tot["withheld"]),
        "explanation": explanation,
        "rules": [{"id": k, "version": v} for k, v in sorted(used.items())],
        "indicators": {k: v for k, v in memo.items()},
        "version": data.version,
    }


def _plain(v):
    return v


def postings(result, data):
    """Journal lines by accounting role (generic): [(role_target, debit, credit, tax)]. The caller posts the
    receivable for the net and the revenue for the total."""
    roles = {t["code"]: _json(t.get("roles")) for t in data.taxes}
    lines = []
    for t in result["taxes"]:
        r = roles.get(t["tax"], {})

        def need(role):
            if not r.get(role):
                raise TaxError("TAX_ROLE_MISSING", f"o tributo {t['tax']} não tem conta para o papel {role}",
                               {"tax": t["tax"], "role": role})
            return r[role]
        if t.get("amount"):
            lines.append((need("expense"), t["amount"], Decimal(0), t["tax"]))
            lines.append((need("payable"), Decimal(0), t["amount"], t["tax"]))
        if t.get("withheld"):
            lines.append((need("withheld"), t["withheld"], Decimal(0), t["tax"]))
        if t.get("credit"):
            lines.append((need("credit"), t["credit"], Decimal(0), t["tax"]))
            lines.append((need("credit_offset"), Decimal(0), t["credit"], t["tax"]))
    return lines


def explain_text(result):
    """'Por que este imposto?' in plain language."""
    out = []
    for e in result["explanation"]:
        crit = ", ".join(f"{k} = {v}" for k, v in e["criteria"].items()) or "regra geral"
        v = e["values"]
        parts = [f"{k} {v[k]}" for k in ("base", "rate", "amount", "withheld", "credit") if v.get(k) is not None]
        where = f"item {e['item'] + 1}" if e["item"] is not None else "documento"
        out.append(f"{e['tax']} ({where}): regra {e['rule_id']} \"{e['rule']}\" porque {crit}; " + ", ".join(parts))
    return out


# --------------------------------------------------------------------------- database (runtime only)

_CACHE = {"version": None, "data": None}


def load():
    """Rules, tables and attributes, cached by the version in tax.state (RNF-049-01)."""
    v = ana.sql_value("SELECT version FROM tax.state")
    if _CACHE["version"] == v and _CACHE["data"] is not None:
        return _CACHE["data"]
    data = Data(
        taxes=ana.sql("SELECT code, name, sequence, scope, roles FROM tax.tax WHERE active"),
        rules=ana.sql("SELECT id, tax, name, valid_from, valid_to, criteria, formulas, status, version "
                      "FROM tax.rule WHERE status = 'active'"),
        tables=ana.sql("SELECT table_name, key, valid_from, valid_to, value, data FROM tax.table_row"),
        attributes=ana.sql("SELECT entity, code, value_type, source FROM tax.attribute"),
        values=ana.sql("SELECT entity, entity_id, attribute, value, valid_from, valid_to FROM tax.attribute_value"),
        indicators=ana.sql("SELECT code, kind, definition FROM tax.indicator"),
        version=v)
    for r in data.rules:
        r["criteria"] = _json(r["criteria"])
        r["formulas"] = _json(r["formulas"]) if not isinstance(r["formulas"], list) else r["formulas"]
    _CACHE.update(version=v, data=data)
    return data


def _registry(entity, ident):
    if ident is None:
        return None
    if entity == "company":
        return ana.sql_one("SELECT row_to_json(c)::text AS j FROM base.company c ORDER BY id LIMIT 1")
    q = {"party": "SELECT row_to_json(p)::text AS j FROM base.party p WHERE id = $1::int",
         "item": "SELECT row_to_json(p)::text AS j FROM base.product p WHERE code = $1",
         "contract": "SELECT row_to_json(p)::text AS j FROM projects.project p WHERE code = $1"}[entity]
    return ana.sql_one(q, str(ident) if entity != "party" else int(ident))


def _row(entity, ident):
    r = _registry(entity, ident)
    return json.loads(r["j"]) if r and r.get("j") else None


def normalize(document, data):
    """Caller's document → normalized document with every attribute valid on the date of the fact."""
    if not isinstance(document, dict):
        raise TaxError("TAX_DOCUMENT", "documento inválido")
    day = as_date(document.get("date"))
    company = _row("company", 1) or {}
    recipient = document.get("recipient")
    rec_row = _row("party", recipient) if isinstance(recipient, (int, str)) and str(recipient).isdigit() else None
    rec_explicit = recipient if isinstance(recipient, dict) else {}
    contract_code = document.get("contract")
    con_row = _row("contract", contract_code) if contract_code else None
    if rec_row is None and con_row and con_row.get("customer_id"):
        rec_row = _row("party", con_row["customer_id"])
    items = []
    for it in document.get("items") or []:
        q = fx.dec(it.get("quantity", 1))
        price = fx.dec(it.get("unit_price", 0))
        disc = fx.dec(it.get("discount", 0))
        amount = fx.dec(it["amount"]) if it.get("amount") is not None else money(q * price - disc)
        code = it.get("code") or it.get("product")
        prow = _row("item", code) if code else None
        items.append({"amount": amount, "quantity": q, "unit_price": price, "discount": disc,
                      "attributes": attributes_of(data, "item", code, prow, day, it.get("attributes"))})
    if not items:
        raise TaxError("TAX_DOCUMENT", "documento sem itens")
    return {
        "date": day.isoformat(),
        "doc": {"operation": document.get("operation"), **(document.get("attributes") or {})},
        "emitter": attributes_of(data, "company", company.get("id"), company, day, document.get("emitter")),
        "recipient": attributes_of(data, "party", (rec_row or {}).get("id"), rec_row, day, rec_explicit),
        "contract": attributes_of(data, "contract", contract_code, con_row, day, None) if contract_code else {},
        "items": items,
    }


def _first_of_month(d):
    return d.replace(day=1)


def _add_months(d, n):
    y, m = divmod(d.month - 1 + n, 12)
    return d.replace(year=d.year + y, month=m + 1, day=1)


def indicator_value(data, code, day, doc_total=Decimal(0), depth=0):
    """Generic indicators: account sums over a window of months, or formulas over other indicators."""
    if depth > 10:
        raise fx.FormulaError("indicadores em ciclo")
    ind = data.indicators.get(code)
    if ind is None:
        raise fx.FormulaError(f"indicador desconhecido: {code}")
    d = _json(ind["definition"])
    if ind["kind"] == "formula":
        c = fx.validate([["amount", d["expression"]]])
        return fx.evaluate(c, {}, {"indicator": lambda c2: indicator_value(data, c2, day, doc_total, depth + 1)})["amount"]
    months = int(d.get("months", 12))
    start = _first_of_month(day)
    window_from = _add_months(start, -months)
    sign = "l.credit - l.debit" if d.get("side", "credit") == "credit" else "l.debit - l.credit"
    prefixes = [str(p) + "%" for p in d.get("account_prefixes", [])]
    exclude = [str(p) + "%" for p in d.get("exclude_prefixes", [])] or ["~none~"]

    def total(f, t):
        return fx.dec(ana.sql_value(
            f"SELECT COALESCE(sum({sign}), 0) FROM finance.journal_line l JOIN finance.journal_entry e ON e.id = l.entry_id "
            "WHERE l.account LIKE ANY($1::text[]) AND NOT l.account LIKE ANY($2::text[]) "
            "  AND e.entry_date >= $3 AND e.entry_date < $4", prefixes, exclude, f, t))
    value = total(window_from, start)
    if d.get("start_rule") == "annualize":
        act = ana.sql_value("SELECT activity_start FROM base.company ORDER BY id LIMIT 1")
        if act is not None and as_date(act) > window_from:
            first = _first_of_month(as_date(act))
            active = (start.year - first.year) * 12 + (start.month - first.month)
            if active <= 0:       # first month of activity: the month itself (plus this document), annualized
                current = total(start, _add_months(start, 1)) + (fx.dec(doc_total) if d.get("include_document") else 0)
                return current * months
            value = total(first, start) / active * months
    return value


def calculate(document, record=None):
    """Calculates a document. record = (doc_kind, doc_ref) stores the calculation (RF-049-11)."""
    data = load()
    doc = normalize(document, data)
    total = sum((i["amount"] for i in doc["items"]), Decimal(0))
    day = as_date(doc["date"])
    fixed = {k: fx.dec(v) for k, v in (document.get("indicators") or {}).items()}   # simulations and test cases
    result = compute(doc, data, lambda code: fixed[code] if code in fixed else indicator_value(data, code, day, total))
    result["postings"] = [{"account": a, "debit": d, "credit": c, "tax": t} for a, d, c, t in postings(result, data)]
    if record:
        kind, ref = record
        payload = canonical({"input": doc, "result": {k: v for k, v in result.items() if k != "explanation"}})
        result["calculation"] = ana.sql_value(
            "INSERT INTO tax.calculation (doc_kind, doc_ref, fact_date, input, rules, result, hash, created_by) "
            "VALUES ($1, $2, $3, $4::text::jsonb, $5::text::jsonb, $6::text::jsonb, $7, $8) RETURNING id",
            kind, str(ref), day, canonical(doc), canonical(result["rules"]), canonical(result),
            hashlib.sha256(payload.encode()).hexdigest(), ana.context.user)
    return result


def account(role_target):
    """A role target is a finance.default_account key or an account code."""
    return ana.sql_value("SELECT CASE WHEN $1 ~ '^[0-9]+(\\.[0-9]+)*$' THEN $1 ELSE finance.account_for($1) END",
                         str(role_target))
