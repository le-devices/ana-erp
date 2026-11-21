# ana:description Cadastro de impostos: permissão, validação de regras, conflitos, casos de teste, ativação e pacotes
# ana:kind library
"""Maintenance of the tax data (spec 049, T-049-01/03/05/07; RNF-049-03; D11/P21).

Every change that can alter a calculation runs the company's test cases with and without the change and
returns the differences; with differences, it only proceeds with `confirm` and a reason, recorded in
tax.change. Generic: no tax or regime is named here.
"""

import copy
import datetime
import hashlib
import importlib  # ana:lint-ok forbidden_import — só import_module de pacotes de regras (tax.package_*)
import json
from decimal import Decimal

from ana_lib.tax import engine, formula as fx


def can_change():
    return ana.context.role == "admin" or bool(ana.sql_value("SELECT tax.can_change($1)", ana.context.user))


def require_tax():
    if not can_change():
        raise ana.Error("FORBIDDEN", "só responsáveis tributários (grupo tax) ou administradores alteram impostos")


def _j(v):
    return json.loads(v) if isinstance(v, str) else v


def known_paths(data):
    paths = {f"{p}.{f}" for p, ent in (("emitter", "company"), ("recipient", "party"), ("contract", "contract"),
                                         ("item", "item")) for f in engine.REGISTRY_FIELDS[ent]}
    paths |= {"emitter.uf", "recipient.uf", "item.amount", "item.quantity", "item.unit_price", "item.discount"}
    prefix = {"company": "emitter", "party": "recipient", "contract": "contract", "item": "item"}
    for a in data.attributes:
        paths.add(f"{prefix[a['entity']]}.{a['code']}")
    return paths


def check_rule(rule, data=None):
    """Validates a rule before saving or activating; raises ana.Error with a clear message (CA-049-05)."""
    data = data or engine.load()
    if not ana.sql_value("SELECT EXISTS (SELECT 1 FROM tax.tax WHERE code = $1)", rule["tax"]):
        raise ana.Error("TAX_UNKNOWN", f"tributo {rule['tax']} não cadastrado")
    crit = rule.get("criteria") or {}
    if not isinstance(crit, dict):
        raise ana.Error("TAX_CRITERIA", "critérios devem ser um objeto {caminho: valor}")
    paths = known_paths(data)
    for p, v in crit.items():
        if p not in paths and not p.startswith("doc."):
            raise ana.Error("TAX_CRITERIA", f"critério com campo desconhecido: {p} (cadastre o atributo antes)")
        if isinstance(v, dict) and set(v) != {"prefix"}:
            raise ana.Error("TAX_CRITERIA", f"critério {p}: use um valor, uma lista ou {{\"prefix\": \"…\"}}")
    try:
        compiled = fx.validate([list(f) for f in rule["formulas"]], paths)
    except fx.FormulaError as e:
        raise ana.Error("TAX_FORMULA", e.text()) from None
    names = {n for n, _ in compiled}
    roles = _j(ana.sql_value("SELECT roles FROM tax.tax WHERE code = $1", rule["tax"])) or {}
    needs = {"amount": ("expense", "payable"), "withheld": ("withheld",), "credit": ("credit", "credit_offset"),
             "charged": ("payable",)}
    for out, rs in needs.items():
        for r in rs:
            if out in names and not roles.get(r):
                raise ana.Error("TAX_ROLE_MISSING", f"o tributo {rule['tax']} não tem conta para o papel {r} (usado por {out})")
    return compiled


# --------------------------------------------------------------------------- test cases before × after

def active_cases():
    return [{**c, "document": _j(c["document"]), "expected": _j(c["expected"])}
            for c in ana.sql("SELECT id, name, document, expected FROM tax.test_case WHERE active ORDER BY id")]


def run_case(case, data):
    doc_in = case["document"]
    try:
        doc = engine.normalize(doc_in, data)
        day = engine.as_date(doc["date"])
        total = sum((i["amount"] for i in doc["items"]), Decimal(0))
        fixed = {k: fx.dec(v) for k, v in (doc_in.get("indicators") or {}).items()}
        r = engine.compute(doc, data, lambda c: fixed[c] if c in fixed else engine.indicator_value(data, c, day, total),
                           company_value=lambda name, at: ana.value(name, at=at))
        return {"ok": True, "taxes": {t["tax"]: {k: str(t[k]) for k in ("base", "rate", "amount", "withheld", "credit", "charged") if k in t}
                                      for t in r["taxes"]}, "totals": {k: str(v) for k, v in r["totals"].items()}}
    except (engine.TaxError, fx.FormulaError) as e:
        return {"ok": False, "error": getattr(e, "message", str(e))}


def expected_failures(case, got):
    if not got["ok"]:
        return [got["error"]]
    out = []
    for tax, fields in (case["expected"].get("taxes") or {}).items():
        for k, v in fields.items():
            have = (got["taxes"].get(tax) or {}).get(k)
            if have is None or Decimal(have) != Decimal(str(v)):
                out.append(f"{tax}.{k}: esperado {v}, calculado {have}")
    for k, v in (case["expected"].get("totals") or {}).items():
        if Decimal(got["totals"].get(k, "0")) != Decimal(str(v)):
            out.append(f"total {k}: esperado {v}, calculado {got['totals'].get(k)}")
    return out


def compare(before, after):
    """[{case, before, after}] for every case whose result changes (CA-049-04)."""
    out = []
    for cid, (case, a) in before.items():
        b = after[cid][1]
        if a != b:
            out.append({"case": case["id"], "name": case["name"], "before": a, "after": b,
                        "expected": expected_failures(case, b)})
    return out


def run_all(data):
    return {c["id"]: (c, run_case(c, data)) for c in active_cases()}


def with_changes(data, add_rules=(), close=None, retire=(), taxes=None, tables=None, attributes=None, indicators=None):
    """A copy of the engine data with the proposed changes, for the before × after run."""
    rules = [r for r in copy.deepcopy(data.rules) if r["id"] not in set(retire)]
    for r in rules:
        if close and r["id"] in close:
            r["valid_to"] = close[r["id"]]
    rules += list(add_rules)
    return engine.Data(taxes=taxes if taxes is not None else data.taxes, rules=rules,
                       tables=tables if tables is not None else data.tables,
                       attributes=attributes if attributes is not None else data.attributes,
                       values=data.values,
                       indicators=indicators if indicators is not None else list(data.indicators.values()),
                       version=-1)


# --------------------------------------------------------------------------- rules

def get_rule(rule_id, lock=False):
    r = ana.sql_one("SELECT id, tax, name, valid_from, valid_to, criteria, formulas, status, version, copied_from, package "
                    "FROM tax.rule WHERE id = $1" + (" FOR UPDATE" if lock else ""), int(rule_id))
    if not r:
        raise ana.Error("TAX_RULE_NOT_FOUND", f"regra {rule_id} não encontrada")
    r["criteria"], r["formulas"] = _j(r["criteria"]), _j(r["formulas"])
    return r


def activate(rule_id, reason, confirm=False):
    """Validates, refuses conflicts (CA-049-03), runs the cases (CA-049-04) and activates."""
    require_tax()
    rule = get_rule(rule_id, lock=True)
    if rule["status"] != "draft":
        raise ana.Error("TAX_RULE_STATE", f"regra {rule_id} não é rascunho ({rule['status']})")
    data = engine.load()
    check_rule(rule, data)
    close = {}
    if rule.get("copied_from"):
        prev = get_rule(rule["copied_from"])
        if prev["status"] == "active" and engine.as_date(rule["valid_from"]) > engine.as_date(prev["valid_from"]):
            close[prev["id"]] = rule["valid_from"] - datetime.timedelta(days=1)
    candidate = {**rule, "status": "active"}
    others = [dict(r, valid_to=close.get(r["id"], r.get("valid_to"))) for r in data.rules]
    clash = engine.conflicts(candidate, others)
    if clash:
        raise ana.Error("TAX_RULE_CONFLICT", "regras igualmente específicas para o mesmo caso: "
                        + "; ".join(f"{c['id']} {c['name']}" for c in clash) + " — torne uma delas mais específica ou ajuste a vigência")
    before = run_all(data)
    after = run_all(with_changes(data, add_rules=[candidate], close=close))
    diffs = compare(before, after)
    if diffs and not confirm:
        return {"activated": False, "needs_confirmation": True, "differences": diffs, "cases": len(before)}
    for pid, until in close.items():
        ana.sql_exec("UPDATE tax.rule SET valid_to = $2 WHERE id = $1", pid, until)
    ana.sql_exec("UPDATE tax.rule SET status = 'active', activated_at = now(), activated_by = $2, reason = $3 WHERE id = $1",
                 rule["id"], ana.context.user, reason)
    ana.sql_exec("INSERT INTO tax.change (kind, target, reason, cases_run, differences, username) "
                 "VALUES ('activate', $1, $2, $3, $4::text::jsonb, $5)",
                 f"rule:{rule['id']}", reason, len(before), engine.canonical(diffs), ana.context.user)
    return {"activated": True, "rule": rule["id"], "closed": [{"rule": k, "valid_to": v} for k, v in close.items()],
            "differences": diffs, "cases": len(before)}


def copy_with_date(rule_id, valid_from, formulas=None, criteria=None, name=None):
    """New validity from an existing rule (RF-049-02): a draft that, when activated, closes the old one."""
    require_tax()
    r = get_rule(rule_id)
    if engine.as_date(valid_from) <= engine.as_date(r["valid_from"]):
        raise ana.Error("TAX_RULE_DATE", "a nova vigência começa depois da atual")
    new = {"tax": r["tax"], "name": name or r["name"], "criteria": criteria if criteria is not None else r["criteria"],
           "formulas": formulas if formulas is not None else r["formulas"]}
    check_rule(new)
    return ana.sql_value(
        "INSERT INTO tax.rule (tax, name, valid_from, criteria, formulas, copied_from, created_by) "
        "VALUES ($1, $2, $3, $4::text::jsonb, $5::text::jsonb, $6, $7) RETURNING id",
        new["tax"], new["name"], engine.as_date(valid_from), engine.canonical(new["criteria"]),
        engine.canonical(new["formulas"]), r["id"], ana.context.user)


# --------------------------------------------------------------------------- packages (D5, RF-049-06)

def load_package(name):
    if not name.replace("_", "").isalnum():
        raise ana.Error("TAX_PACKAGE", "nome de pacote inválido")
    try:
        # ana:lint-ok dynamic_import — nome validado acima e espaço fixo ana_lib.tax.package_*: só pacotes de regras
        return importlib.import_module(f"ana_lib.tax.package_{name}")
    except ImportError:
        raise ana.Error("TAX_PACKAGE", f"pacote {name} não encontrado (programa tax.package_{name})") from None


def package_content(pkg):
    keys = ("ACCOUNTS", "ATTRIBUTES", "INDICATORS", "TAXES", "TABLES", "RULES", "CASES", "CODES")
    content = {k.lower(): getattr(pkg, k, []) for k in keys}
    content["version"] = getattr(pkg, "VERSION", "")
    return content


def package_hash(content):
    return hashlib.sha256(engine.canonical(content).encode()).hexdigest()


def package_status(name):
    pkg = load_package(name)
    content = package_content(pkg)
    applied = ana.sql_one("SELECT version, hash, applied_at, applied_by FROM tax.package WHERE name = $1", pkg.NAME)
    return {"name": pkg.NAME, "title": getattr(pkg, "TITLE", pkg.NAME), "notice": getattr(pkg, "NOTICE", ""),
            "version": content["version"], "hash": package_hash(content), "applied": applied,
            "pending": not applied or applied["hash"] != package_hash(content)}


def apply_package(name, reason, confirm=False):
    """Compares the package with what is active, runs the cases with both and applies (CA-049-04)."""
    require_tax()
    pkg = load_package(name)
    content = package_content(pkg)
    pname = pkg.NAME
    data = engine.load()
    existing = {(r["package_key"], str(r["valid_from"])): r for r in
                ana.sql("SELECT id, package_key, valid_from, criteria, formulas, name, status FROM tax.rule "
                        "WHERE package = $1 AND status = 'active'", pname)}
    add, retire, keep = [], [], set()
    taxes = {t["code"]: t for t in data.taxes}
    for t in content["taxes"]:
        taxes[t["code"]] = {**taxes.get(t["code"], {}), **t}
    tmp_id = -1
    for r in content["rules"]:
        k = (r["key"], str(engine.as_date(r["valid_from"])))
        cur = existing.get(k)
        same = cur and _j(cur["criteria"]) == r.get("criteria", {}) and _j(cur["formulas"]) == r["formulas"] and cur["name"] == r["name"]
        if same:
            keep.add(cur["id"])
            continue
        if cur:
            retire.append(cur["id"])
        add.append({**r, "id": tmp_id, "status": "active", "version": 1, "criteria": r.get("criteria", {})})
        tmp_id -= 1
    retire += [r["id"] for k, r in existing.items() if r["id"] not in keep and r["id"] not in retire]
    tables = [t for t in data.tables if t.get("package") != pname] + [dict(t) for t in content["tables"]]
    attrs = {(a["entity"], a["code"]): a for a in data.attributes}
    for a in content["attributes"]:
        attrs[(a["entity"], a["code"])] = a
    inds = dict(data.indicators)
    for i in content["indicators"]:
        inds[i["code"]] = i
    proposed = with_changes(data, add_rules=add, retire=retire, taxes=list(taxes.values()), tables=tables,
                            attributes=list(attrs.values()), indicators=list(inds.values()))
    for r in add:                                            # every formula must be valid before anything changes
        try:
            fx.validate([list(f) for f in r["formulas"]], known_paths(proposed))
        except fx.FormulaError as e:
            raise ana.Error("TAX_FORMULA", f"pacote {pname}, regra {r['key']}: {e.text()}") from None
    before = run_all(data)
    after = run_all(proposed)
    diffs = compare(before, after)
    if diffs and not confirm:
        return {"applied": False, "needs_confirmation": True, "differences": diffs, "cases": len(before),
                "rules_new": len(add), "rules_retired": len(retire)}
    _write_package(pname, content, add, retire, reason)
    case_results = []
    after_cases = run_all(engine.load())
    for cid, (case, got) in after_cases.items():
        fails = expected_failures(case, got)
        if fails:
            case_results.append({"case": case["id"], "name": case["name"], "failures": fails})
    ana.sql_exec("INSERT INTO tax.change (kind, target, reason, cases_run, differences, username) "
                 "VALUES ('package', $1, $2, $3, $4::text::jsonb, $5)",
                 f"package:{pname}@{content['version']}", reason, len(after_cases), engine.canonical(diffs), ana.context.user)
    return {"applied": True, "package": pname, "version": content["version"], "rules_new": len(add),
            "rules_retired": len(retire), "differences": diffs, "cases": len(after_cases), "case_failures": case_results}


def _write_package(pname, content, add, retire, reason):
    user = ana.context.user
    for a in content.get("accounts", []):      # accounts the package needs; the company's choices are never overwritten
        ana.sql_exec("INSERT INTO finance.account (code, description, nature, postable, cost_center_policy) "
                     "VALUES ($1, $2, $3, true, $4) ON CONFLICT DO NOTHING", a["code"], a["description"], a["nature"],
                     a.get("cost_center_policy", "none"))
        if a.get("key"):
            ana.sql_exec("INSERT INTO finance.default_account (key, account, description) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING",
                         a["key"], a["code"], a.get("key_description") or a["description"])
    for t in content["taxes"]:
        ana.sql_exec("INSERT INTO tax.tax (code, name, sequence, scope, roles, package, updated_by) "
                     "VALUES ($1, $2, $3, $4, $5::text::jsonb, $6, $7) ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, "
                     "sequence = EXCLUDED.sequence, scope = EXCLUDED.scope, roles = tax.tax.roles || EXCLUDED.roles, "
                     "package = EXCLUDED.package, updated_at = now(), updated_by = EXCLUDED.updated_by",
                     t["code"], t["name"], int(t.get("sequence", 100)), t.get("scope", "item"),
                     engine.canonical(t.get("roles", {})), pname, user)
    for a in content["attributes"]:
        ana.sql_exec("INSERT INTO tax.attribute (entity, code, value_type, code_list, source, description, package) "
                     "VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT (entity, code) DO UPDATE SET value_type = EXCLUDED.value_type, "
                     "code_list = EXCLUDED.code_list, source = EXCLUDED.source, description = EXCLUDED.description, package = EXCLUDED.package",
                     a["entity"], a["code"], a.get("value_type", "text"), a.get("code_list"), a.get("source"),
                     a.get("description", ""), pname)
    for i in content["indicators"]:
        ana.sql_exec("INSERT INTO tax.indicator (code, kind, definition, description, package) "
                     "VALUES ($1, $2, $3::text::jsonb, $4, $5) ON CONFLICT (code) DO UPDATE SET kind = EXCLUDED.kind, "
                     "definition = EXCLUDED.definition, description = EXCLUDED.description, package = EXCLUDED.package",
                     i["code"], i["kind"], engine.canonical(i["definition"]), i.get("description", ""), pname)
    ana.sql_exec("DELETE FROM tax.table_row WHERE package = $1", pname)
    if content["tables"]:
        ana.sql_batch("INSERT INTO tax.table_row (table_name, key, valid_from, valid_to, value, data, package, updated_by) "
                      "VALUES ($1, $2, $3, $4, $5, $6::text::jsonb, $7, $8)",
                      [[t["table_name"], str(t["key"]), _date(t.get("valid_from")), _date(t.get("valid_to")),
                        None if t.get("value") is None else Decimal(str(t["value"])), engine.canonical(t.get("data", {})),
                        pname, user] for t in content["tables"]])
    for c in content.get("codes", []):
        ana.sql_exec("INSERT INTO tax.code (list, code, description, valid_from, valid_to, package) VALUES ($1, $2, $3, $4, $5, $6) "
                     "ON CONFLICT (list, code) DO UPDATE SET description = EXCLUDED.description, valid_from = EXCLUDED.valid_from, "
                     "valid_to = EXCLUDED.valid_to, package = EXCLUDED.package",
                     c["list"], c["code"], c.get("description", ""), _date(c.get("valid_from")), _date(c.get("valid_to")), pname)
    if retire:
        ana.sql_exec("UPDATE tax.rule SET status = 'retired', reason = $2 WHERE id = ANY($1)", retire,
                     f"substituída pelo pacote {pname}: {reason}")
    for r in add:
        ana.sql_exec("INSERT INTO tax.rule (tax, name, valid_from, valid_to, criteria, formulas, status, package, package_key, "
                     "reason, created_by, activated_at, activated_by) VALUES ($1, $2, $3, $4, $5::text::jsonb, $6::text::jsonb, "
                     "'active', $7, $8, $9, $10, now(), $10)",
                     r["tax"], r["name"], engine.as_date(r["valid_from"]), _date(r.get("valid_to")),
                     engine.canonical(r.get("criteria", {})), engine.canonical(r["formulas"]), pname, r["key"],
                     f"pacote {pname} {content['version']}: {reason}", user)
    for c in content["cases"]:
        ana.sql_exec("INSERT INTO tax.test_case (name, document, expected, package, package_key, updated_by) "
                     "VALUES ($1, $2::text::jsonb, $3::text::jsonb, $4, $5, $6) ON CONFLICT (package, package_key) "
                     "WHERE package IS NOT NULL DO UPDATE SET name = EXCLUDED.name, document = EXCLUDED.document, "
                     "expected = EXCLUDED.expected, updated_at = now(), updated_by = EXCLUDED.updated_by",
                     c["name"], engine.canonical(c["document"]), engine.canonical(c["expected"]), pname, c["key"], user)
    ana.sql_exec("INSERT INTO tax.package (name, version, hash, applied_by) VALUES ($1, $2, $3, $4) "
                 "ON CONFLICT (name) DO UPDATE SET version = EXCLUDED.version, hash = EXCLUDED.hash, applied_at = now(), "
                 "applied_by = EXCLUDED.applied_by", pname, content["version"], package_hash(content), user)


def _date(v):
    return None if v in (None, "") else engine.as_date(v)


# --------------------------------------------------------------------------- watch (P19)

def alerts(today=None):
    """What needs the tax officer: packages not applied, validity ending without a successor, indicators near a
    declared threshold, rules in conflict. Computed on demand (writes nothing, P15)."""
    today = today or datetime.date.today()
    out = []
    for name in [r["name"] for r in ana.sql("SELECT name FROM tax.packages()")]:
        try:
            st = package_status(name)
        except ana.Error:
            continue
        if st["pending"]:
            out.append({"kind": "package", "severity": "warning", "target": st["name"],
                        "text": f"pacote {st['title']} {st['version']} ainda não aplicado",
                        "action": {"program": "tax.apply_package", "params": {"package": name}}})
    data = engine.load()
    horizon = today + datetime.timedelta(days=45)
    for r in data.rules:
        if r.get("valid_to") and today <= engine.as_date(r["valid_to"]) <= horizon:
            nxt = [o for o in data.rules if o["tax"] == r["tax"] and o["id"] != r["id"] and o.get("criteria") == r.get("criteria")
                   and engine.as_date(o["valid_from"]) > engine.as_date(r["valid_to"])]
            if not nxt:
                out.append({"kind": "validity", "severity": "warning", "target": f"rule:{r['id']}",
                            "text": f"regra {r['id']} \"{r['name']}\" termina em {engine.as_date(r['valid_to']):%d/%m/%Y} sem regra seguinte",
                            "action": {"program": "tax.copy_rule", "params": {"rule": r["id"]}}})
    for code, ind in data.indicators.items():
        w = _j(ind["definition"]).get("watch")
        if not w:
            continue
        try:
            v = engine.indicator_value(data, code, today)
        except (fx.FormulaError, ana.Error):
            continue
        th, margin = Decimal(str(w["threshold"])), Decimal(str(w.get("margin", "0")))
        if abs(v - th) <= margin:
            out.append({"kind": "indicator", "severity": "warning", "target": f"indicator:{code}",
                        "text": f"{w.get('message') or code}: hoje {v} (limite {th})", "value": str(v)})
    for t in data.tables:                       # estimated values (e.g. a rate still waiting for the law) in use soon
        d = _j(t.get("data")) or {}
        if d.get("estimated") and engine.valid_on(t, today) or (d.get("estimated") and t.get("valid_from")
                                                             and today < engine.as_date(t["valid_from"]) <= horizon):
            out.append({"kind": "estimated", "severity": "warning", "target": f"table:{t['table_name']}:{t['key']}:{t.get('valid_from')}",
                        "text": f"tabela {t['table_name']} ({t['key']}, a partir de {engine.as_date(t['valid_from']):%d/%m/%Y}) usa valor "
                                f"estimado: {d.get('note') or 'confirme o valor oficial'}",
                        "action": {"program": "tax.import_table", "params": {"table": t["table_name"]}}})
    seen = set()
    for r in data.rules:
        for c in engine.conflicts(r, data.rules):
            pair = tuple(sorted((r["id"], c["id"])))
            if pair not in seen:
                seen.add(pair)
                out.append({"kind": "conflict", "severity": "serious", "target": f"rules:{pair[0]}-{pair[1]}",
                            "text": f"regras {pair[0]} e {pair[1]} igualmente específicas para o mesmo caso"})
    return out


def contract_rate(code, rate, withheld, on=None):
    """A rate typed on a project (legacy field of spec 008) becomes a rule of that contract — two criteria, so it
    wins over the general rule of a package. The project manager may set it; a change opens a new validity."""
    rate = Decimal(str(rate or 0))
    tax = ana.sql_value("SELECT code FROM tax.tax WHERE code = 'iss'")
    if tax is None:
        if rate <= 0:
            return None
        ana.sql_exec("INSERT INTO tax.tax (code, name, sequence, scope, roles, updated_by) VALUES ('iss', 'ISS', 30, 'item', "
                     "'{\"expense\": \"tax_on_revenue\", \"payable\": \"iss_payable\", \"withheld\": \"iss_payable\"}', $1)",
                     ana.context.user)
    on = on or datetime.date.today()
    crit = {"contract.code": code, "doc.operation": "service_sale"}
    formulas = [["base", "amount"], ["rate", str(rate.quantize(Decimal("0.0001")))], ["amount", "round(base * rate, 2)"]] + ([["withheld", "amount"]] if withheld else [])
    cur = ana.sql_one("SELECT id, valid_from, formulas FROM tax.rule WHERE tax = 'iss' AND status = 'active' "
                      "AND criteria = $1::text::jsonb AND (valid_to IS NULL OR valid_to >= $2) ORDER BY valid_from DESC LIMIT 1",
                      engine.canonical(crit), on)
    if cur and _j(cur["formulas"]) == formulas:
        return cur["id"]
    if cur:
        if engine.as_date(cur["valid_from"]) >= on:
            ana.sql_exec("UPDATE tax.rule SET status = 'retired', reason = 'alíquota do projeto alterada' WHERE id = $1", cur["id"])
        else:
            ana.sql_exec("UPDATE tax.rule SET valid_to = $2 WHERE id = $1", cur["id"], on - datetime.timedelta(days=1))
    if rate <= 0:
        return None
    return ana.sql_value(
        "INSERT INTO tax.rule (tax, name, valid_from, criteria, formulas, status, created_by, activated_at, activated_by, reason) "
        "VALUES ('iss', $1, $2, $3::text::jsonb, $4::text::jsonb, 'active', $5, now(), $5, 'alíquota informada no projeto') RETURNING id",
        f"ISS do projeto {code} (alíquota informada no projeto)", on, engine.canonical(crit), engine.canonical(formulas),
        ana.context.user)
