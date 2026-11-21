# ana:description Importa uma tabela de apoio de impostos em CSV (alíquotas por município, por ano, faixas)
# ana:exposed yes
# ana:category Fiscal/Cadastros fiscais
"""Support tables with validity (spec 049, D5). CSV with header: key;valid_from;valid_to;value[;other columns → data].
Rows of the same key whose validity overlaps are refused with the line. `rehearse` shows without saving."""

import csv
import io
from decimal import Decimal, InvalidOperation

from ana_lib.tax import admin, engine

PARAMS = {
    "table": {"type": "str", "required": True, "label": "tabela (ex.: iss_city)"},
    "csv": {"type": "str", "required": True, "label": "conteúdo CSV (separado por ;)", "multiline": True},
    "replace": {"type": "bool", "default": False, "label": "substituir as linhas da empresa nesta tabela"},
    "rehearse": {"type": "bool", "default": True, "label": "ensaio (mostra sem gravar)"},
}


def main(table, csv, replace=False, rehearse=True):
    admin.require_tax()
    reader = list(_csv(csv))
    if not reader or "key" not in reader[0]:
        raise ana.ParamError("a primeira linha precisa das colunas key;valid_from;valid_to;value")
    rows = []
    for n, r in enumerate(reader[1:], start=2):
        rec = dict(zip(reader[0], r))
        try:
            value = None if not rec.get("value") else Decimal(rec["value"].replace(",", "."))
        except InvalidOperation:
            raise ana.ParamError(f"linha {n}: valor inválido {rec.get('value')!r}") from None
        data = {k: v for k, v in rec.items() if k not in ("key", "valid_from", "valid_to", "value") and v != ""}
        rows.append([table, rec["key"].strip(), _d(rec.get("valid_from")), _d(rec.get("valid_to")), value,
                     engine.canonical(data), ana.context.user])
    ana.table([{"chave": r[1], "de": r[2], "até": r[3], "valor": r[4]} for r in rows[:200]],
              title=f"{len(rows)} linha(s) para {table}" + (" — ensaio, nada gravado" if rehearse else ""))
    if rehearse:
        ana.actions([{"label": "Gravar", "program": "tax.import_table", "style": "primary",
                      "params": {"table": table, "csv": csv, "replace": replace, "rehearse": False}}], title="Confira e grave")
        return {"rows": len(rows), "saved": False}
    if replace:
        ana.sql_exec("DELETE FROM tax.table_row WHERE table_name = $1 AND package IS NULL", table)
    try:
        ana.sql_batch("INSERT INTO tax.table_row (table_name, key, valid_from, valid_to, value, data, updated_by) "
                      "VALUES ($1, $2, $3, $4, $5, $6::text::jsonb, $7)", rows)
    except ana.SqlError as e:
        raise ana.Error("TAX_TABLE_OVERLAP", f"vigências sobrepostas para a mesma chave: {e}") from None
    return {"rows": len(rows), "saved": True}


def _csv(text):
    return csv.reader(io.StringIO(text.strip()), delimiter=";")


def _d(v):
    return None if not v or not v.strip() else engine.as_date(v.strip())
