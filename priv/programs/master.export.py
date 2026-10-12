# ana:description Cadastros: exporta uma entidade mestre em CSV, no formato que a importação lê de volta
# ana:exposed yes
"""Spec 040 (RF-040-09, RNF-040-04). Header with the field labels (the import recognizes them); text cells
that a spreadsheet would run as a formula (= + - @) are neutralized with a leading apostrophe."""

import csv
import io

from ana_lib.master import core

PARAMS = {"entity": {"type": "str", "required": True, "label": "cadastro"},
          "active": {"type": "str", "default": "true", "label": "situação", "choices": [["true", "Ativos"], ["false", "Inativos"], ["all", "Todos"]]},
          "q": {"type": "str", "label": "buscar"}}


def safe(v, f):
    if v is None:
        return ""
    s = str(v)
    if f.get("type", "text") in ("text", "email", "url", "lookup", "choice", "tax_id") and s[:1] in ("=", "+", "-", "@"):
        return "'" + s
    if f.get("type") in ("decimal", "money", "percent"):
        return s.replace(".", ",")
    return s


def main(entity, active="true", q=None):
    d = core.entity(entity)
    core.require(d, "view")
    fields = [f for f in d["fields"] if not f.get("computed") and not (f.get("secret") and core.role() != "admin")]
    cols = ", ".join(f"{core.expr(f)} AS f_{f['name']}" for f in fields)
    where, args = ["true"], []
    if active in ("true", "false"):
        args.append(active == "true")
        where.append(f"t.active = ${len(args)}")
    if q:
        args.append(q)
        where.append(f"{d['search']} LIKE '%' || base.norm(${len(args)}) || '%'")
    rows = ana.sql(f"SELECT t.{d['key']} AS _key, {cols} FROM {d['table']} t WHERE {' AND '.join(where)} ORDER BY {d['order']} "
                   "LIMIT 200000", *args)
    buf = io.StringIO()
    w = csv.writer(buf, delimiter=";")
    key_label = "Código" if d["key"] != "id" else "Identificador"
    w.writerow([key_label] + [f["label"] for f in fields if f["name"] != d["key"]])
    for r in rows:
        w.writerow([str(r["_key"])] + [safe(r[f"f_{f['name']}"], f) for f in fields if f["name"] != d["key"]])
    return {"filename": f"{entity}.csv", "rows": len(rows), "content": "﻿" + buf.getvalue()}
