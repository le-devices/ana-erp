# ana:description CNPJ (também alfanumérico) e CPF: validar, formatar, tipo de pessoa e raiz, pela regra do banco
# ana:kind library
"""Spec 043 (RF-043-06). The rule lives in the database (base.valid_tax_id, base.format_tax_id…): this
library asks it, so programs, the record sheets, imports and triggers can never disagree. Answers are
kept for the execution; prefetch() checks a whole column in one query (imports)."""

import ana

_cache = {}


def _key(value):
    return str(value or "").strip()


def prefetch(values):
    """Checks many documents in one query; later calls to check/valid/format answer from memory."""
    todo = sorted({_key(v) for v in values if _key(v) and _key(v) not in _cache})
    for i in range(0, len(todo), 5000):
        part = todo[i:i + 5000]
        for r in ana.sql("SELECT v, base.valid_tax_id(v) AS ok, base.format_tax_id(v) AS formatted, "
                         "base.person_kind(v) AS kind, base.tax_id_root(v) AS root FROM unnest($1::text[]) AS v", part):
            _cache[r["v"]] = (r["ok"], r["formatted"], r["kind"], r["root"])


def _info(value):
    k = _key(value)
    if not k:
        return (True, None, None, None)
    if k not in _cache:
        prefetch([k])
    return _cache[k]


def valid(value):
    """True for a valid CPF or CNPJ (numeric or alphanumeric); empty counts as valid (not informed)."""
    return _info(value)[0]


def format(value):
    """Formatted document (000.000.000-00 or AA.AAA.AAA/AAAA-00), or None when empty."""
    return _info(value)[1]


def kind(value):
    """'individual' (CPF), 'company' (CNPJ) or None."""
    return _info(value)[2]


def root(value):
    """The first 8 positions of a CNPJ (same company, any branch), or None."""
    return _info(value)[3]


def check(value, field="CNPJ/CPF"):
    """Formatted document; ana.Error INVALID_TAX_ID when it is not valid."""
    ok, formatted, _, _ = _info(value)
    if not ok:
        raise ana.Error("INVALID_TAX_ID", f"{field} {value} inválido: confira os números e letras (dígito verificador)")
    return formatted
