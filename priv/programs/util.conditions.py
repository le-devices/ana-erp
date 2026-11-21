# ana:description Regra restrita (condições sem código): avaliar, validar e escrever em português
# ana:kind library
"""Spec 020 (RF-020-14) and 030 (RF-030-02). The same rule the core evaluates (ana_flows:condition/2) —
esteiras, BPM, simulations — never code. Two shapes:

    [rule, ...]                                  every rule holds (the first format, still valid)
    {"any": [[rule, ...], ...], "except": [rule]} some criterion (all its rules) holds and no exception does

Rule: {"field", "op", "value"}. Usage:

    from ana_lib.util import conditions
    conditions.validate(cond)                    # raises ana.Error with the reason
    conditions.holds(cond, {"total": 1200})      # True / False
    conditions.text(cond, {"total": "Total"})    # "Total maior que 1.000, exceto Cliente bloqueado é sim"
"""

import ana

OPS = {"=": "é", "!=": "não é", "<": "menor que", "<=": "até", ">": "maior que", ">=": "a partir de",
       "in": "é um de", "not_in": "não é nenhum de", "between": "entre", "contains": "contém",
       "not_contains": "não contém", "starts": "começa com", "empty": "está vazio", "not_empty": "está preenchido"}
NO_VALUE = {"empty", "not_empty"}
LISTS = {"in", "not_in"}
MAX_RULES = 50


def normalize(cond):
    """{"any": [[...]], "except": [...]} from either shape (a list is one criterion)."""
    if cond is None:
        return {"any": [], "except": []}
    if isinstance(cond, list):
        return {"any": [cond] if cond else [], "except": []}
    if isinstance(cond, dict):
        return {"any": [c for c in cond.get("any") or [] if isinstance(c, list)],
                "except": [r for r in cond.get("except") or [] if isinstance(r, dict)]}
    raise ana.Error("INVALID_PARAMETER", "condição deve ser uma lista de regras ou {any, except}")


def compact(n):
    """The stored rule: a plain list when there is one criterion and no exception (the first format)."""
    n = normalize(n)
    any_ = [c for c in n["any"] if c]
    if not n["except"] and len(any_) <= 1:
        return any_[0] if any_ else []
    return {"any": any_, "except": n["except"]}


def validate(cond, fields=None):
    """Checks shape, operators and values; `fields` (names) limits the fields allowed. Returns the normalized rule."""
    n = normalize(cond)
    rules = [r for c in n["any"] for r in c] + n["except"]
    if len(rules) > MAX_RULES:
        raise ana.Error("INVALID_PARAMETER", f"no máximo {MAX_RULES} linhas por condição")
    for r in rules:
        f, op = r.get("field"), r.get("op")
        if not isinstance(f, str) or not f.strip():
            raise ana.Error("INVALID_PARAMETER", "toda linha precisa de um campo")
        if fields is not None and f not in fields:
            raise ana.Error("INVALID_PARAMETER", f"campo desconhecido: {f}")
        if op not in OPS:
            raise ana.Error("INVALID_PARAMETER", f"operador desconhecido: {op}")
        v = r.get("value")
        if op in LISTS and not (isinstance(v, list) and v):
            raise ana.Error("INVALID_PARAMETER", f"{f}: informe a lista de valores")
        if op == "between" and not (isinstance(v, list) and len(v) == 2):
            raise ana.Error("INVALID_PARAMETER", f"{f}: entre pede dois valores")
        if op not in NO_VALUE and op not in LISTS and op != "between" and (v is None or v == ""):
            raise ana.Error("INVALID_PARAMETER", f"{f}: informe o valor")
    return n


def _num(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return v
    if isinstance(v, str):
        try:
            return int(v)
        except ValueError:
            try:
                return float(v)
            except ValueError:
                return None
    try:                       # Decimal
        return float(v)
    except (TypeError, ValueError):
        return None


def _text(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float) and v.is_integer():
        return repr(v)
    return str(v)


def _same(a, b):
    x, y = _num(a), _num(b)
    if x is not None and y is not None:
        return x == y
    return _text(a) == _text(b)


def _blank(v):
    return v is None or v == "" or v == []


def _compare(op, x, y):
    return {"<": x < y, "<=": x <= y, ">": x > y, ">=": x >= y}.get(op, False)


def rule_holds(r, facts):
    a, op, v = facts.get(r.get("field")), r.get("op"), r.get("value")
    if op == "empty":
        return _blank(a)
    if op == "not_empty":
        return not _blank(a)
    if op in LISTS and isinstance(v, list):
        hit = any(_same(a, x) for x in v)
        return hit if op == "in" else not hit
    if op == "=":
        return _same(a, v)
    if op == "!=":
        return not _same(a, v)
    if op in ("contains", "not_contains"):
        hit = _text(v).lower() in _text(a).lower()
        return hit if op == "contains" else not hit
    if op == "starts":
        return _text(a).lower().startswith(_text(v).lower())
    if op == "between" and isinstance(v, list) and len(v) == 2:
        x, lo, hi = _num(a), _num(v[0]), _num(v[1])
        if None not in (x, lo, hi):
            return min(lo, hi) <= x <= max(lo, hi)
        return not _blank(a) and _text(v[0]) <= _text(a) <= _text(v[1])
    x, y = _num(a), _num(v)
    if x is not None and y is not None:
        return _compare(op, x, y)
    if isinstance(a, str) and isinstance(v, str) and a != "":
        return _compare(op, a, v)          # ISO dates compare as text
    return False


def holds(cond, facts):
    """Same answer as the core (ana_flows:condition/2)."""
    if isinstance(cond, list):
        return all(rule_holds(r, facts) for r in cond)
    if not isinstance(cond, dict):
        return False
    n = normalize(cond)
    return ((not n["any"] or any(all(rule_holds(r, facts) for r in c) for c in n["any"]))
            and not any(rule_holds(r, facts) for r in n["except"]))


def _value_text(v):
    if isinstance(v, bool):
        return "sim" if v else "não"
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        s = f"{v:,.2f}" if isinstance(v, float) and not float(v).is_integer() else f"{int(v):,}"
        return s.replace(",", "X").replace(".", ",").replace("X", ".")
    return str(v)


def _rule_text(r, labels):
    f = labels.get(r.get("field"), r.get("field"))
    op, v = r.get("op"), r.get("value")
    if op in NO_VALUE:
        return f"{f} {OPS[op]}"
    if op in LISTS and isinstance(v, list):
        vals = [_value_text(x) for x in v]
        joined = vals[0] if len(vals) == 1 else ", ".join(vals[:-1]) + " ou " + vals[-1]
        return f"{f} {'é' if op == 'in' else 'não é'} {joined}"
    if op == "between" and isinstance(v, list) and len(v) == 2:
        return f"{f} entre {_value_text(v[0])} e {_value_text(v[1])}"
    return f"{f} {OPS.get(op, op)} {_value_text(v)}"


def text(cond, labels=None):
    """The rule in Portuguese: "Filial é AK01 ou AK02, exceto Cliente bloqueado é sim"."""
    labels = labels or {}
    n = normalize(cond)
    crit = [" e ".join(_rule_text(r, labels) for r in c) for c in n["any"] if c]
    out = "sempre" if not crit else crit[0] if len(crit) == 1 else " ou ".join(f"({c})" for c in crit)
    if n["except"]:
        out += ", exceto " + " ou ".join(_rule_text(r, labels) for r in n["except"])
    return out
