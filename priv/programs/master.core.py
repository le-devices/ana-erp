# ana:description Serviço padrão de dados mestres: descrever, buscar, ler, validar, salvar, desativar, histórico, duplicados
# ana:kind library
"""Spec 040. Every master entity is handled the same way, from its declaration in master.entities:
validation (also in the database for the critical ones), optimistic version (xmin), duplicates,
approval of sensitive fields, and the entity's writer program (its business rules) to save.

Identifiers come only from the declarations and are checked before entering SQL; values are always
parameters. Authorization uses the execution context (it cannot be forged by SQL)."""

import datetime
import re
from decimal import Decimal, InvalidOperation

import ana
from ana_lib.master import entities as E

ROLE_RANK = {"user": 0, "developer": 1, "admin": 2}
IDENT = re.compile(r"^[a-z_][a-z0-9_]*$")
QUALIFIED = re.compile(r"^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$")
UF = {"AC", "AL", "AP", "AM", "BA", "CE", "DF", "ES", "GO", "MA", "MT", "MS", "MG", "PA", "PB", "PR", "PE", "PI", "RJ", "RN",
      "RS", "RO", "RR", "SC", "SP", "SE", "TO"}
ACTIONS = {"view": "ver", "edit": "alterar", "approve": "aprovar"}


# ---------------------------------------------------------------- declarations
def _ident(name, qualified=False):
    if not (QUALIFIED if qualified else IDENT).match(str(name)):
        raise ana.Error("INTERNAL", f"identificador inválido na definição: {name}")
    return name


def entity(name):
    base = E.ENTITIES.get(str(name or ""))
    if not base:
        raise ana.Error("ENTITY_NOT_FOUND", f"cadastro {name} não existe")
    d = dict(base, name=name)
    _ident(d["table"], True)
    _ident(d["id"])
    _ident(d["key"])
    fields = [dict(f) for f in d["fields"]]
    for f in fields:
        _ident(f["name"])
    if d.get("custom"):
        for c in ana.sql("SELECT name, label, type, required, choices FROM master.custom_field WHERE entity = $1 AND active "
                         "ORDER BY position, name", name):
            fields.append({"name": _ident(c["name"]), "label": c["label"], "type": c["type"], "required": c["required"],
                           "choices": [[x, x] for x in c["choices"]] if c["type"] == "choice" else None, "custom": True})
    d["fields"] = fields
    tabs = []
    for t in d.get("tabs", []):
        t = dict(t)
        if t["kind"] != "view":
            _ident(t["table"], True)
            _ident(t["fk"])
            for f in t["fields"]:
                _ident(f["name"])
        tabs.append(t)
    d["tabs"] = tabs
    return d


def role():
    return ana.context.role or "user"


def can(d, action):
    if role() == "admin":
        return True
    need = d.get("permissions", {}).get(action, "admin" if action == "approve" else "user")
    return ROLE_RANK.get(role(), 0) >= ROLE_RANK.get(need, 2)


def require(d, action):
    if not can(d, action):
        raise ana.Error("FORBIDDEN", f"sem permissão para {ACTIONS.get(action, action)} {d['plural'].lower()}")


def key_value(d, key):
    """The key as the database stores it (integer ids, text codes)."""
    if key is None or key == "":
        return None
    if d["key"] == "id" or d["key"].endswith("_id"):
        try:
            return int(key)
        except (TypeError, ValueError):
            raise ana.Error("NOT_FOUND", f"{d['label'].lower()} {key} não encontrado") from None
    return str(key).strip().upper() if any(f.get("upper") for f in d["fields"] if f["name"] == d["key"]) else str(key).strip()


def expr(f, alias="t"):
    if f.get("custom"):
        return f"{alias}.custom ->> '{_ident(f['name'])}'"
    return f.get("expr") or f"{alias}.{f['name']}"


def public_field(f):
    out = {k: f[k] for k in ("name", "label", "type", "required", "choices", "ref", "readonly", "list", "sensitive",
                             "help", "default", "max", "lookup", "computed", "custom", "upper") if f.get(k) is not None}
    if f.get("secret") and role() != "admin":
        out["hidden"] = True
    return out


def describe(name=None):
    """Definitions for the screen (and for integrations): only what the user may see."""
    names = [name] if name else list(E.ENTITIES)
    policies = {r["entity"]: r["approval"] for r in ana.sql("SELECT entity, approval FROM master.policy")}
    out = []
    for n in names:
        d = entity(n)
        if not can(d, "view"):
            continue
        out.append({"name": n, "label": d["label"], "plural": d["plural"], "group": d["group"], "key": d["key"],
                    "fields": [public_field(f) for f in d["fields"]],
                    "tabs": [{"label": t["label"], "kind": t["kind"], "fields": [public_field(f) for f in t.get("fields", [])]}
                             for t in d["tabs"]],
                    "can_edit": can(d, "edit"), "can_approve": can(d, "approve"), "approval": bool(policies.get(n)),
                    "quality": [q["label"] for q in d.get("quality", [])]})
    return out


# ---------------------------------------------------------------- values
def _decimal(v):
    if isinstance(v, (int, float, Decimal)) and not isinstance(v, bool):
        return Decimal(str(v))
    s = str(v).strip().replace("R$", "").replace("%", "").strip()
    if "," in s:
        s = s.replace(".", "").replace(",", ".")
    return Decimal(s)


def tax_id_ok(v):
    d = re.sub(r"\D", "", v)
    if len(d) == 11 and len(set(d)) > 1:
        for n in (9, 10):
            s = sum(int(d[i]) * (n + 1 - i) for i in range(n))
            r = (s * 10) % 11 % 10
            if r != int(d[n]):
                return None
        return f"{d[:3]}.{d[3:6]}.{d[6:9]}-{d[9:]}"
    if len(d) == 14 and len(set(d)) > 1:
        w = [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
        for n in (12, 13):
            s = sum(int(d[i]) * w[i + (13 - n)] for i in range(n))
            r = s % 11
            if (0 if r < 2 else 11 - r) != int(d[n]):
                return None
        return f"{d[:2]}.{d[2:5]}.{d[5:8]}/{d[8:12]}-{d[12:]}"
    return None


def coerce(f, value):
    """(value, error message or None). Empty → None; the same rules for the screen, the API and imports."""
    if value is None or (isinstance(value, str) and value.strip() == ""):
        return None, ("obrigatório" if f.get("required") else None)
    t = f.get("type", "text")
    try:
        if t in ("text", "url", "lookup"):
            v = str(value).strip()
            if f.get("upper"):
                v = v.upper()
            if f.get("max") and len(v) > f["max"]:
                return None, f"no máximo {f['max']} caracteres"
            if t == "url" and not re.match(r"^https?://\S+$", v):
                return None, "endereço deve começar com http:// ou https://"
            return v, None
        if t == "int":
            return int(_decimal(value)), None
        if t in ("decimal", "money", "percent"):
            v = _decimal(value)
            if t == "money" and v < 0:
                return None, "não pode ser negativo"
            if t == "percent" and not (0 <= v <= 100):
                return None, "deve ficar entre 0 e 100"
            return v, None
        if t == "bool":
            if isinstance(value, bool):
                return value, None
            s = str(value).strip().lower()
            if s in ("true", "1", "sim", "s", "yes", "x"):
                return True, None
            if s in ("false", "0", "não", "nao", "n", "no"):
                return False, None
            return None, "use sim ou não"
        if t == "date":
            if isinstance(value, datetime.date):
                return value, None
            s = str(value).strip()
            for fmt in ("%Y-%m-%d", "%d/%m/%Y"):
                try:
                    return datetime.datetime.strptime(s[:10], fmt).date(), None
                except ValueError:
                    pass
            return None, "data inválida (use dd/mm/aaaa)"
        if t == "choice":
            allowed = [str(c[0]) for c in (f.get("choices") or [])]
            if str(value) not in allowed:
                return None, "escolha uma das opções"
            return str(value), None
        if t == "email":
            v = str(value).strip().lower()
            if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", v):
                return None, "e-mail inválido"
            return v, None
        if t == "tax_id":
            v = tax_id_ok(str(value))
            return (v, None) if v else (None, "CNPJ/CPF inválido: confira os números (dígito verificador)")
        if t == "state":
            v = str(value).strip().upper()
            return (v, None) if v in UF else (None, "UF inválida")
        if t == "ref":
            return value, None          # existence and activity checked together in check_refs
    except (InvalidOperation, ValueError, TypeError):
        return None, "número inválido"
    return value, None


def ref_by(f):
    return f.get("ref_by") or ("id" if f["name"].endswith("_id") else "key")


def ref_column(r, by):
    return r["id"] if by == "id" else r["key"]


def check_refs(fields, values, errors, prefix=""):
    """Every reference exists and is active (an inactive record cannot enter new data)."""
    for f in fields:
        v = values.get(f["name"])
        if f.get("type") != "ref" or v is None or f.get("computed"):
            continue
        r = entity(f["ref"])
        col = ref_column(r, ref_by(f))
        where = f" AND ({f['filter']})" if f.get("filter") else ""
        row = ana.sql_one(f"SELECT t.active FROM {r['table']} t WHERE t.{col}::text = $1{where}", str(v))
        if not row:
            errors[prefix + f["name"]] = f"{r['label'].lower()} {v} não encontrado"
        elif row["active"] is False:
            errors[prefix + f["name"]] = f"{r['label'].lower()} {v} está inativo"


def titles(ref, values, by):
    """{stored value: title} of records of another entity (for lists and sheets)."""
    vals = sorted({str(v) for v in values if v is not None})
    if not vals:
        return {}
    r = entity(ref)
    col = ref_column(r, by)
    return {str(x["v"]): x["title"] for x in ana.sql(
        f"SELECT t.{col}::text AS v, {r['title']} AS title FROM {r['table']} t WHERE t.{col}::text = ANY($1::text[])", vals)}


# ---------------------------------------------------------------- search and read
def search(name, q=None, filters=None, active="true", offset=0, limit=50):
    d = entity(name)
    require(d, "view")
    limit = max(1, min(int(limit or 50), 500))
    offset = max(0, int(offset or 0))
    listed = [f for f in d["fields"] if f.get("list") and not (f.get("secret") and role() != "admin")]
    cols = ", ".join(f"{expr(f)} AS f_{f['name']}" for f in listed)
    where, args = ["true"], []
    if active in ("true", "false"):
        args.append(active == "true")
        where.append(f"t.active = ${len(args)}")
    if q and str(q).strip():
        args.append(str(q).strip())
        where.append(f"{d['search']} LIKE '%' || base.norm(${len(args)}) || '%'")
    by_name = {f["name"]: f for f in d["fields"]}
    for k, v in (filters or {}).items():
        if k in by_name and v not in (None, ""):
            args.append(str(v))
            where.append(f"({expr(by_name[k])})::text = ${len(args)}")
    w = " AND ".join(where)
    total = ana.sql_value(f"SELECT count(*) FROM {d['table']} t WHERE {w}", *args)
    rows = ana.sql(f"SELECT t.{d['id']} AS _id, t.{d['key']} AS _key, {d['title']} AS _title, t.active AS _active"
                   f"{', ' + cols if cols else ''} FROM {d['table']} t WHERE {w} ORDER BY {d['order']}, t.{d['id']} "
                   f"LIMIT {limit} OFFSET {offset}", *args)
    out = []
    refs = {f["name"]: titles(f["ref"], [r[f"f_{f['name']}"] for r in rows], ref_by(f)) for f in listed if f.get("type") == "ref"}
    for r in rows:
        values = {}
        for f in listed:
            v = r[f"f_{f['name']}"]
            values[f["name"]] = v
            if f["name"] in refs and v is not None:
                values[f["name"] + "__title"] = refs[f["name"]].get(str(v))
        out.append({"id": r["_id"], "key": r["_key"], "title": r["_title"], "active": r["_active"], "values": values})
    return {"entity": name, "total": total, "offset": offset, "limit": limit, "rows": out,
            "columns": [public_field(f) for f in listed]}


def options(name, q=None, limit=2000, by="key", filter_sql=None):
    """The single lookup of the ERP (RF-040-04): active records, the same text and order everywhere."""
    d = entity(name)
    args, where = [], ["t.active"]
    if q and str(q).strip():
        args.append(str(q).strip())
        where.append(f"{d['search']} LIKE '%' || base.norm(${len(args)}) || '%'")
    if filter_sql:
        where.append(f"({filter_sql})")
    col = d["id"] if by == "id" else d["key"]
    rows = ana.sql(f"SELECT t.{col} AS v, {d['title']} AS label FROM {d['table']} t WHERE {' AND '.join(where)} "
                   f"ORDER BY {d['order']} LIMIT {max(1, min(int(limit), 5000))}", *args)
    return [{"value": r["v"], "label": r["label"]} for r in rows]


def current_values(d, ids):
    """{id: {field: value}} for many records in one query (imports)."""
    if not ids:
        return {}
    cols = ", ".join(f"{expr(f)} AS f_{f['name']}" for f in d["fields"])
    rows = ana.sql(f"SELECT t.{d['id']}::text AS _id, t.{d['key']} AS _key, {cols} FROM {d['table']} t "
                   f"WHERE t.{d['id']}::text = ANY($1::text[])", [str(i) for i in ids])
    return {r["_id"]: {"key": r["_key"], "values": {f["name"]: r[f"f_{f['name']}"] for f in d["fields"]}} for r in rows}


def read_main(d, key, lock=False):
    fields = [f for f in d["fields"]]
    cols = ", ".join(f"{expr(f)} AS f_{f['name']}" for f in fields)
    raw = ", ".join(f"{f['unchanged_expr']} AS r_{f['name']}" for f in fields if f.get("unchanged_expr"))
    row = ana.sql_one(f"SELECT t.{d['id']} AS _id, t.{d['key']} AS _key, {d['title']} AS _title, t.active AS _active, "
                      f"t.xmin::text AS _version, {cols}{', ' + raw if raw else ''} FROM {d['table']} t "
                      f"WHERE t.{d['key']} = $1{' FOR UPDATE OF t' if lock else ''}", key_value(d, key))
    if not row:
        raise ana.Error("NOT_FOUND", f"{d['label'].lower()} {key} não encontrado")
    return row


def read_tab(d, t, main_id):
    if t["kind"] == "view":
        rows = ana.sql(t["sql"], main_id)
        after = ana.sql(t["after"], main_id) if t.get("after") else []
        return {"rows": rows, "after": after}
    cols = ", ".join(f"{expr(f)} AS {f['name']}" for f in t["fields"])
    rows = ana.sql(f"SELECT {cols} FROM {t['table']} t WHERE t.{t['fk']} = $1 ORDER BY 1", main_id)
    if t["kind"] == "one":
        return rows[0] if rows else {}
    return rows


def mask(fields, values):
    if role() == "admin":
        return values
    hidden = {f["name"] for f in fields if f.get("secret")}
    return {k: ("***" if k in hidden and v is not None else v) for k, v in values.items()}


def get(name, key):
    d = entity(name)
    require(d, "view")
    row = read_main(d, key)
    values = {f["name"]: row[f"f_{f['name']}"] for f in d["fields"]}
    tabs = {}
    for t in d["tabs"]:
        tv = read_tab(d, t, row["_id"])
        if t["kind"] == "one":
            tv = mask(t["fields"], tv)
        elif t["kind"] == "rows":
            tv = [mask(t["fields"], r) for r in tv]
        tabs[t["label"]] = tv
    ref_titles = {}
    for f in d["fields"]:
        if f.get("type") == "ref" and values.get(f["name"]) is not None:
            ref_titles[f["name"]] = titles(f["ref"], [values[f["name"]]], ref_by(f)).get(str(values[f["name"]]))
    pending = ana.sql("SELECT id, title, changes, requested_by, requested_at FROM master.change_request "
                      "WHERE entity = $1 AND row_key = $2 AND status = 'pending' ORDER BY id", name, str(row["_id"]))
    return {"entity": name, "id": row["_id"], "key": row["_key"], "title": row["_title"], "active": row["_active"],
            "version": row["_version"], "values": mask(d["fields"], values), "titles": ref_titles, "tabs": tabs,
            "pending": pending}


# ---------------------------------------------------------------- duplicates (RF-040-07)
def duplicates(name, values, exclude_id=None):
    d = entity(name)
    found = {}
    for rule in d.get("duplicates", []):
        f = rule["field"]
        v = values.get(f)
        if v in (None, ""):
            continue
        col = next((expr(x) for x in d["fields"] if x["name"] == f), None)
        if not col:
            continue
        if rule["kind"] == "exact":
            rows = ana.sql(f"SELECT t.{d['id']} AS id, t.{d['key']} AS key, {d['title']} AS title, t.active FROM {d['table']} t "
                           f"WHERE base.norm({col}) = base.norm($1) AND ($2::text IS NULL OR t.{d['id']}::text <> $2) LIMIT 5",
                           str(v), None if exclude_id is None else str(exclude_id))
            why = f"mesmo {next(x['label'] for x in d['fields'] if x['name'] == f)}"
        else:
            rows = ana.sql(f"SELECT t.{d['id']} AS id, t.{d['key']} AS key, {d['title']} AS title, t.active FROM {d['table']} t "
                           f"WHERE public.similarity(base.norm({col}), base.norm($1)) >= $2 "
                           f"AND ($3::text IS NULL OR t.{d['id']}::text <> $3) "
                           f"ORDER BY public.similarity(base.norm({col}), base.norm($1)) DESC LIMIT 5",
                           str(v), rule.get("threshold", 0.6), None if exclude_id is None else str(exclude_id))
            why = f"{next(x['label'] for x in d['fields'] if x['name'] == f).lower()} parecido"
        for r in rows:
            found.setdefault(str(r["id"]), {"id": r["id"], "key": r["key"], "title": r["title"], "active": r["active"],
                                            "reasons": []})["reasons"].append(why)
    return list(found.values())[:10]


# ---------------------------------------------------------------- save (RF-040-03, 08)
def validate(d, values, current=None):
    """Clean values of the main fields + {field: message}."""
    clean, errors = {}, {}
    for f in d["fields"]:
        if f.get("computed"):
            continue
        if current is not None and f["name"] not in values:
            clean[f["name"]] = current.get(f["name"])
            continue
        raw = values.get(f["name"], f.get("default") if current is None else None)
        v, err = coerce(f, raw)
        if err:
            errors[f["name"]] = err
        if current is not None and f.get("readonly") and v is not None and str(v) != str(current.get(f["name"])):
            errors[f["name"]] = "não pode ser alterado depois de criado"
        clean[f["name"]] = v
    check_refs(d["fields"], clean, errors)
    return clean, errors


def validate_tab(t, rows, errors):
    out = []
    for i, r in enumerate(rows):
        c = {}
        for f in t["fields"]:
            raw = r.get(f["name"], f.get("default"))
            v, err = coerce(f, raw)
            if err:
                errors[f"{t['label']}.{i}.{f['name']}"] = err
            c[f["name"]] = v
        check_refs(t["fields"], c, errors, f"{t['label']}.{i}.")
        out.append(c)
    return out


def param_value(f, v):
    if v is None:
        return None
    if f.get("type") == "ref" and f.get("ref_param") == "key" and ref_by(f) == "id":
        r = entity(f["ref"])
        return ana.sql_value(f"SELECT t.{r['key']} FROM {r['table']} t WHERE t.{r['id']} = $1", v)
    if isinstance(v, Decimal):
        return str(v)
    if isinstance(v, datetime.date):
        return v.isoformat()
    return v


def writer_params(fields, values):
    return {f.get("param", f["name"]): param_value(f, values.get(f["name"]))
            for f in fields if not f.get("computed") and not f.get("custom")}


def changes_of(fields, before, after):
    out = {}
    for f in fields:
        if f.get("computed"):
            continue
        a, b = (before or {}).get(f["name"]), after.get(f["name"])
        if str(a if a is not None else "") != str(b if b is not None else ""):
            out[f["name"]] = [None if a is None else str(a), None if b is None else str(b)]
    return out


def save(name, key=None, values=None, tabs=None, version=None, confirm_duplicate=False, reason=None, approved_request=None,
         light=False):
    """light=True (imports): returns only {id, key} and records no duplicate note (the import is the reason)."""
    d = entity(name)
    require(d, "edit")
    values, tabs = values or {}, tabs or {}
    current = None
    if key not in (None, ""):
        row = read_main(d, key, lock=True)
        if version and version != row["_version"]:
            raise ana.Error("CONFLICT", "outra pessoa alterou este cadastro depois que você o abriu: recarregue e refaça a alteração",
                            {"current": get(name, key)})
        current = {f["name"]: row[f"f_{f['name']}"] for f in d["fields"]}
        raw = {f["name"]: row[f"r_{f['name']}"] for f in d["fields"] if f.get("unchanged_expr")}
        main_id = row["_id"]
    else:
        raw, main_id = {}, None
    clean, errors = validate(d, values, current)
    tab_data = {}
    for t in d["tabs"]:
        if t["kind"] == "view" or t["label"] not in tabs:
            continue
        given = tabs[t["label"]]
        if t["kind"] == "one":
            tab_data[t["label"]] = validate_tab(t, [given or {}], errors)[0]
        else:
            tab_data[t["label"]] = validate_tab(t, list(given or []), errors)
    if errors:
        raise ana.Error("INVALID_FIELDS", "corrija os campos destacados", {"fields": errors})

    if current is None and not confirm_duplicate:
        dup = duplicates(name, clean)
        if dup:
            raise ana.Error("POSSIBLE_DUPLICATE", "já existe cadastro parecido: use o existente ou confirme que é outro",
                            {"candidates": dup})
    if current is None and confirm_duplicate and len((reason or "").strip()) < 3:
        raise ana.Error("INVALID_PARAMETER", "diga por que não é duplicado (fica no histórico)")

    # Sensitive fields under approval: the change waits for another person (four eyes).
    if current is not None and approved_request is None and ana.sql_value(
            "SELECT approval FROM master.policy WHERE entity = $1", name):
        sens = {f["name"] for f in d["fields"] if f.get("sensitive")}
        changed = changes_of(d["fields"], current, clean)
        tab_changed = {}
        for t in d["tabs"]:
            if t["label"] in tab_data and t["kind"] == "one":
                old = read_tab(d, t, main_id)
                c = changes_of(t["fields"], old, tab_data[t["label"]])
                tab_changed.update({f"{t['label']}.{k}": v for k, v in c.items()
                                    if any(f["name"] == k and f.get("sensitive") for f in t["fields"])})
        if sens & set(changed) or tab_changed:
            rid = ana.sql_value(
                "INSERT INTO master.change_request (entity, row_key, title, changes, requested_by) VALUES ($1, $2, $3, $4, $5) "
                "RETURNING id", name, str(main_id), str(row["_title"]),
                {"values": {k: (str(v) if isinstance(v, (Decimal, datetime.date)) else v) for k, v in values.items()},
                 "tabs": _jsonable(tabs), "diff": {**{k: v for k, v in changed.items()}, **tab_changed}, "version": version},
                ana.context.user)
            ana.sql_exec("INSERT INTO master.change_log (entity, row_key, table_name, op, changes, username, origin) "
                         "VALUES ($1, $2, $3, 'request', $4, $5, 'master')", name, str(main_id), d["table"],
                         {**changed, **tab_changed}, ana.context.user)
            return {"pending": rid, "entity": name, "key": key,
                    "message": "alteração de campo sensível enviada para aprovação de outra pessoa"}

    params = writer_params(d["fields"], clean)
    for f in d["fields"]:
        if f.get("unchanged_param") and current is not None and str(clean.get(f["name"])) == str(current.get(f["name"])):
            params.pop(f.get("param", f["name"]), None)
            params[f["unchanged_param"]] = raw.get(f["name"])
    if current is not None and d.get("writer_key"):
        params[d["writer_key"]] = main_id
    if d.get("writer_active"):
        params["active"] = True if current is None else bool(row["_active"])
    for t in d["tabs"]:
        if t.get("list_param"):
            rows = tab_data.get(t["label"])
            if rows is None and current is not None:
                rows = read_tab(d, t, main_id)
            params[t["list_param"]] = [writer_params(t["fields"], r) for r in (rows or [])]
    result = ana.call(d["writer"], **params) or {}
    new_key = result.get(d["key"]) if isinstance(result, dict) else None
    if new_key is None:
        new_key = key if current is not None else (result.get("id") if d["key"] == "id" else clean.get(d["key"]))
    saved = read_main(d, new_key)
    main_id = saved["_id"]

    custom = {f["name"]: param_value(f, clean.get(f["name"])) for f in d["fields"] if f.get("custom")}
    if custom:
        ana.sql_exec(f"UPDATE {d['table']} t SET custom = t.custom || $2 WHERE t.{d['id']} = $1", main_id, custom)

    for t in d["tabs"]:
        if t["label"] not in tab_data or t.get("list_param"):
            continue
        parent = main_id if t.get("parent_value", "id") == "id" else saved["_key"]
        if t["kind"] == "one":
            old = read_tab(d, t, main_id)
            data = tab_data[t["label"]]
            if changes_of(t["fields"], old, data) and (old or any(v not in (None, False, "") for v in data.values())):
                ana.call(t["writer"], **{t["parent_param"]: parent, **writer_params(t["fields"], data)})
            continue
        old_rows = read_tab(d, t, main_id)
        rk = lambda r: tuple(str(r.get(k)) for k in t["row_key"])
        old = {rk(r): r for r in old_rows}
        new = {rk(r): r for r in tab_data[t["label"]]}
        for k, r in new.items():
            if k not in old or changes_of(t["fields"], old[k], r):
                ana.call(t["writer"], **{t["parent_param"]: parent, **writer_params(t["fields"], r)})
        for k, r in old.items():
            if k in new:
                continue
            if t.get("remove") == "delete":
                cond = " AND ".join(f"t.{_ident(c)}::text = ${i + 2}" for i, c in enumerate(t["row_key"]))
                ana.sql_exec(f"DELETE FROM {t['table']} t WHERE t.{t['fk']} = $1 AND {cond}", main_id, *[str(r.get(c)) for c in t["row_key"]])
            elif str(t.get("remove", "")).startswith("param:"):
                keys = {f.get("param", f["name"]): param_value(f, r.get(f["name"])) for f in t["fields"] if f["name"] in t["row_key"]}
                full = writer_params(t["fields"], r)
                ana.call(t["writer"], **{t["parent_param"]: parent, **full, **keys, t["remove"][6:]: True})
    if light:
        return {"id": main_id, "key": saved["_key"]}
    if current is None and confirm_duplicate:
        ana.sql_exec("INSERT INTO master.change_log (entity, row_key, table_name, op, changes, username, origin) "
                     "VALUES ($1, $2, $3, 'note', $4, $5, 'master')", name, str(main_id), d["table"],
                     {"duplicate_confirmed": [None, reason.strip()]}, ana.context.user)
    return get(name, saved["_key"])


def _jsonable(x):
    if isinstance(x, dict):
        return {k: _jsonable(v) for k, v in x.items()}
    if isinstance(x, list):
        return [_jsonable(v) for v in x]
    if isinstance(x, (Decimal, datetime.date)):
        return str(x)
    return x


# ---------------------------------------------------------------- lifecycle (RF-040-05)
def set_active(name, keys, active):
    d = entity(name)
    require(d, "edit")
    vals = [key_value(d, k) for k in keys]
    n = ana.sql_exec(f"UPDATE {d['table']} t SET active = $2 WHERE t.{d['key']} = ANY($1) AND t.active <> $2", vals, bool(active))
    return {"changed": n}


def references(d, main_id):
    """Where the record is used: every foreign key pointing to the main table, with counts."""
    schema, table = d["table"].split(".")
    fks = ana.sql(
        "SELECT fn.nspname || '.' || f.relname AS tbl, a.attname AS col FROM pg_constraint c "
        "JOIN pg_class f ON f.oid = c.conrelid JOIN pg_namespace fn ON fn.oid = f.relnamespace "
        "JOIN pg_class r ON r.oid = c.confrelid JOIN pg_namespace rn ON rn.oid = r.relnamespace "
        "JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1] "
        "WHERE c.contype = 'f' AND rn.nspname = $1 AND r.relname = $2 AND cardinality(c.conkey) = 1 "
        "  AND (SELECT attname FROM pg_attribute WHERE attrelid = c.confrelid AND attnum = c.confkey[1]) = $3 "
        "ORDER BY 1, 2", schema, table, d["id"])
    out = []
    for fk in fks:
        _ident(fk["tbl"], True)
        _ident(fk["col"])
        n = ana.sql_value("SELECT master.reference_count($1, $2, $3)", fk["tbl"], fk["col"], str(main_id))
        if n:
            out.append({"table": fk["tbl"], "column": fk["col"], "rows": n})
    return out


def delete(name, key):
    d = entity(name)
    require(d, "edit")
    row = read_main(d, key, lock=True)
    own = {t["table"] for t in d["tabs"] if t["kind"] != "view"}
    used = [u for u in references(d, row["_id"]) if u["table"] not in own and u["rows"]]
    if used:
        raise ana.Error("IN_USE", "este cadastro já foi usado e não pode ser apagado: desative-o", {"used": used})
    try:
        with ana.savepoint():
            for t in d["tabs"]:
                if t["kind"] != "view":
                    ana.sql_exec(f"DELETE FROM {t['table']} t WHERE t.{t['fk']} = $1", row["_id"])
            ana.sql_exec(f"DELETE FROM {d['table']} t WHERE t.{d['id']} = $1", row["_id"])
    except ana.SqlError as e:
        if e.sqlstate == "23503":                     # referenced somewhere this role cannot see
            raise ana.Error("IN_USE", "este cadastro já foi usado e não pode ser apagado: desative-o", {"used": []}) from None
        raise
    return {"deleted": True, "key": row["_key"]}


def history(name, key, limit=200):
    d = entity(name)
    require(d, "view")
    row = read_main(d, key)
    labels = {f["name"]: f["label"] for f in d["fields"]}
    for t in d["tabs"]:
        for f in t.get("fields", []):
            labels.setdefault(f["name"], f"{t['label']}: {f['label']}")
    rows = ana.sql("SELECT at, op, table_name, changes, username, origin FROM master.change_log "
                   "WHERE entity = $1 AND row_key = $2 ORDER BY id DESC LIMIT $3", name, str(row["_id"]), int(limit))
    secret = {f["name"] for f in d["fields"] if f.get("secret")} if role() != "admin" else set()
    out = []
    for r in rows:
        for field, (before, after) in (r["changes"] or {}).items():
            if field in ("id", "custom", d["id"]) and r["op"] == "insert":
                continue
            masked = field in secret
            out.append({"at": r["at"], "op": r["op"], "field": labels.get(field, field), "before": "***" if masked else before,
                        "after": "***" if masked else after, "by": r["username"], "origin": r["origin"]})
    return out


# ---------------------------------------------------------------- merge (RF-040-07)
def merge(name, keep, drop, reason):
    d = entity(name)
    if role() != "admin":
        raise ana.Error("FORBIDDEN", "só o administrador mescla cadastros")
    if len((reason or "").strip()) < 3:
        raise ana.Error("INVALID_PARAMETER", "diga o motivo da mesclagem")
    k = read_main(d, keep, lock=True)
    x = read_main(d, drop, lock=True)
    if k["_id"] == x["_id"]:
        raise ana.Error("INVALID_PARAMETER", "escolha dois cadastros diferentes")
    moved = {}
    for u in references(d, x["_id"]):
        try:
            with ana.savepoint():
                n = ana.sql_exec(f"UPDATE {u['table']} SET {u['column']} = $1 WHERE {u['column']} = $2", k["_id"], x["_id"])
        except ana.Error as e:
            raise ana.Error("MERGE_BLOCKED", f"não foi possível mover as referências em {u['table']}: {e.message} — "
                            "desative o duplicado em vez de mesclar", {"table": u["table"]}) from None
        if n:
            moved[u["table"]] = n
    ana.sql_exec(f"UPDATE {d['table']} t SET active = false WHERE t.{d['id']} = $1", x["_id"])
    ana.sql_exec("INSERT INTO master.change_log (entity, row_key, table_name, op, changes, username, origin) "
                 "VALUES ($1, $2, $3, 'merge', $4, $5, 'master')", name, str(k["_id"]), d["table"],
                 {"merged_from": [str(x["_key"]), str(k["_key"])], "reason": [None, reason.strip()],
                  "moved": [None, ", ".join(f"{t}: {n}" for t, n in moved.items()) or "nada"]}, ana.context.user)
    return {"kept": k["_key"], "dropped": x["_key"], "moved": moved}


# ---------------------------------------------------------------- quality (RF-040-10)
def quality(name=None):
    out = []
    for n in ([name] if name else list(E.ENTITIES)):
        d = entity(n)
        if not can(d, "view"):
            continue
        total = ana.sql_value(f"SELECT count(*) FROM {d['table']} t WHERE t.active")
        items = []
        for q in d.get("quality", []):
            cnt = ana.sql_value(f"SELECT count(*) FROM {d['table']} t WHERE t.active AND ({q['where']})")
            items.append({"label": q["label"], "count": cnt, "hint": q["hint"]})
        out.append({"entity": n, "plural": d["plural"], "active": total, "items": items})
    return out


def quality_rows(name, label, limit=200):
    d = entity(name)
    require(d, "view")
    q = next((x for x in d.get("quality", []) if x["label"] == label), None)
    if not q:
        raise ana.Error("NOT_FOUND", f"indicador {label} não existe")
    return ana.sql(f"SELECT t.{d['key']} AS key, {d['title']} AS title FROM {d['table']} t WHERE t.active AND ({q['where']}) "
                   f"ORDER BY {d['order']} LIMIT {int(limit)}")
