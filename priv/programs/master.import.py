# ana:description Cadastros: importa planilha CSV com prévia linha a linha (novo, altera, igual, erro) e confirmação
# ana:exposed yes
# ana:category Cadastros/Dados mestres
"""Spec 040 (RF-040-09, CA-040-06). The same validation as the screen and the API. Preview first; confirm
writes the valid lines in one transaction (a line refused by the business rules is reported and the
others go on). Re-importing the same file does not duplicate: a line matching an existing record by
key or by an exact duplicate rule (same document, same name) updates it or is skipped."""

import csv
import io

from ana_lib.master import core
from ana_lib.util import tax_id as tid

PARAMS = {
    "entity": {"type": "str", "required": True, "label": "cadastro"},
    "content": {"type": "str", "required": True, "label": "conteúdo do CSV"},
    "mapping": {"type": "dict", "label": "coluna da planilha → campo (vazio = pelos nomes)"},
    "confirm": {"type": "bool", "default": False, "label": "gravar as linhas válidas"},
}
MAX_LINES = 100000


def norm(s):
    return str(s or "").strip().lower().translate(str.maketrans("áàâãäéèêëíìîïóòôõöúùûüç", "aaaaaeeeeiiiiooooouuuuc"))


def main(entity, content, mapping=None, confirm=False):
    d = core.entity(entity)
    core.require(d, "edit")
    text = content.lstrip("﻿")
    try:
        dialect = csv.Sniffer().sniff(text[:4096], delimiters=";,\t")
    except csv.Error:
        dialect = csv.excel
        dialect.delimiter = ";"
    rows = list(csv.reader(io.StringIO(text), dialect))
    if not rows:
        raise ana.Error("INVALID_PARAMETER", "arquivo vazio")
    if len(rows) - 1 > MAX_LINES:
        raise ana.Error("TOO_LARGE", f"no máximo {MAX_LINES} linhas por importação")
    header = rows[0]
    fields = [f for f in d["fields"] if not f.get("computed")]
    by_norm = {}
    for f in fields:
        by_norm[norm(f["name"])] = f["name"]
        by_norm[norm(f["label"])] = f["name"]
    by_norm[norm(d["key"])] = "__key"
    by_norm["identificador"] = "__key"
    if d["key"] != "id":
        by_norm["codigo"] = "__key"
    cols = []
    for h in header:
        target = (mapping or {}).get(h) or by_norm.get(norm(h))
        cols.append(target)
    if not any(c for c in cols):
        raise ana.Error("INVALID_PARAMETER", "nenhuma coluna reconhecida: use os nomes dos campos no cabeçalho")
    exact = [r["field"] for r in d.get("duplicates", [])]
    parsed = []
    for n, line in enumerate(rows[1:], start=2):
        if not any(c.strip() for c in line):
            continue
        values, key = {}, None
        for c, v in zip(cols, line):
            if c == "__key":
                key = v.strip() or None
            elif c:
                values[c] = v
        if key is None and d["key"] in values:
            key = values.get(d["key"])
        if key and any(f["name"] == d["key"] for f in fields):
            values[d["key"]] = key          # the business key is also a field (code): needed to create
        parsed.append((n, key, values))
    # Spec 043: every document of the file checked by the database in one query, not one per line.
    doc_fields = [f["name"] for f in fields if f.get("type") == "tax_id"]
    if doc_fields:
        tid.prefetch(v.get(f) for _, _, v in parsed for f in doc_fields)
    found = match_existing(d, parsed, exact)          # line → id of an existing record (key or exact rule)
    current = core.current_values(d, sorted(set(found.values())))
    result, counts = [], {"new": 0, "update": 0, "same": 0, "error": 0}
    for n, key, values in parsed:
        cur = current.get(found.get(n))
        status, msg = "new", ""
        try:
            if cur is not None:
                clean, errors = core.validate(d, values, cur["values"])
                changed = core.changes_of([f for f in fields if f["name"] in values], cur["values"], clean)
                status = "update" if changed else "same"
                msg = "; ".join(f"{k}: {a or '—'} → {b or '—'}" for k, (a, b) in changed.items())
            else:
                clean, errors = core.validate(d, values)
            if errors:
                status, msg = "error", "; ".join(f"{next((f['label'] for f in fields if f['name'] == k), k)}: {e}" for k, e in errors.items())
        except ana.Error as e:
            status, msg = "error", e.message
        if confirm and status in ("new", "update"):
            try:
                with ana.savepoint():
                    core.save(entity, str(cur["key"]) if cur else None, values, None, None,
                              confirm_duplicate=cur is None, reason="importação", light=True)
            except ana.Error as e:
                status, msg = "error", e.message
        counts[status] += 1
        title = values.get(d["key"]) or next((v for v in values.values() if v), "")
        result.append({"linha": n, "situação": {"new": "novo", "update": "altera", "same": "igual", "error": "erro"}[status],
                       "registro": title, "detalhe": msg})
    ana.metrics([{"label": "Novos", "value": counts["new"]}, {"label": "Alterações", "value": counts["update"]},
                 {"label": "Iguais", "value": counts["same"]},
                 {"label": "Com erro", "value": counts["error"], "status": "bad" if counts["error"] else "ok"}],
                title="Importação gravada" if confirm else "Prévia da importação")
    shown = [r for r in result if r["situação"] != "igual"][:500]
    ana.table(shown, title="Linhas" + (" (primeiras 500)" if len(shown) == 500 else ""))
    if not confirm and (counts["new"] or counts["update"]):
        ana.actions([{"label": f"Gravar {counts['new'] + counts['update']} linha(s) válida(s)", "program": "master.import",
                      "style": "primary", "params": {"entity": entity, "content": content, "mapping": mapping, "confirm": True}}],
                    title="Próximo passo")
    return {"entity": entity, "confirmed": bool(confirm), **counts,
            "columns": {h: c for h, c in zip(header, cols)}, "errors": [r for r in result if r["situação"] == "erro"][:1000]}


def match_existing(d, parsed, exact_fields):
    """{line: id}: an existing record by its key, or by the same document/e-mail/normalized name (batched)."""
    out = {}
    keys = {str(k): n for n, k, _ in parsed if k}
    if keys:
        kv = sorted(keys)
        for r in ana.sql(f"SELECT t.{d['key']}::text AS k, t.{d['id']}::text AS id FROM {d['table']} t "
                         f"WHERE t.{d['key']}::text = ANY($1::text[])", kv):
            for n, k, _ in parsed:
                if str(k) == r["k"]:
                    out[n] = r["id"]
    for f in exact_fields:
        col = next((core.expr(x) for x in d["fields"] if x["name"] == f), None)
        if not col:
            continue
        wanted = {}
        for n, _, values in parsed:
            v = values.get(f)
            if n in out or not v or not str(v).strip():
                continue
            if f == "tax_id":
                v = (tid.format(v) if tid.valid(v) else None) or v
            wanted.setdefault(str(v).strip().lower(), []).append(n)
        if not wanted:
            continue
        rows = ana.sql(f"SELECT DISTINCT ON (base.norm({col})) base.norm({col}) AS v, t.{d['id']}::text AS id FROM {d['table']} t "
                       f"WHERE base.norm({col}) IN (SELECT base.norm(x) FROM unnest($1::text[]) x)", list(wanted))
        by_norm = {r["v"]: r["id"] for r in rows}
        for v, lines in wanted.items():
            hit = by_norm.get(ana_norm(v))
            if hit:
                for n in lines:
                    out.setdefault(n, hit)
    return out


def ana_norm(s):
    return str(s or "").lower().translate(str.maketrans("áàâãäéèêëíìîïóòôõöúùûüçñ", "aaaaaeeeeiiiiooooouuuucn"))
