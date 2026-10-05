# ana:description Importa extrato bancário (OFX ou CSV) sem duplicar lançamentos
# ana:exposed yes
# ana:command extrato
"""RF-017-06. Deduplication by the bank's transaction id (OFX FITID or a CSV id column) or,
without it, by a hash of date + amount + description (+ the occurrence number inside the file,
so two equal transactions on the same day are both kept). Lines go in batches of 5 000
(one INSERT … SELECT FROM unnest each, ON CONFLICT DO NOTHING)."""

import datetime
import hashlib
import re
from decimal import Decimal, InvalidOperation

PARAMS = {
    "bank_account": {"type": "str", "required": True, "label": "conta bancária", "order": 1,
                     "lookup": {"program": "finance.lookup", "params": {"kind": "bank_accounts"}}},
    "format": {"type": "str", "default": "ofx", "label": "formato", "order": 2,
               "choices": [["ofx", "OFX"], ["csv", "CSV (planilha)"]]},
    "content": {"type": "str", "required": True, "label": "conteúdo do arquivo", "order": 3},
    "file_name": {"type": "str", "label": "nome do arquivo", "order": 4},
    "csv_layout": {"type": "dict", "label": "layout do CSV", "order": 5,
                   "help": "colunas (a partir de 0): date, amount, description, document, id; delimiter; date_format; "
                           "decimal (',' ou '.'); skip (linhas de cabeçalho)"},
}
CHUNK = 5000
DEFAULT_LAYOUT = {"date": 0, "description": 1, "amount": 2, "document": None, "id": None,
                  "delimiter": ";", "date_format": "%d/%m/%Y", "decimal": ",", "skip": 1}


def main(bank_account, content, format="ofx", file_name=None, csv_layout=None):
    acc = ana.sql_one("SELECT code FROM finance.bank_account WHERE code = $1 AND active", bank_account.strip().upper())
    if not acc:
        raise ana.Error("BANK_ACCOUNT_NOT_FOUND", f"conta bancária {bank_account} não encontrada")
    if format == "ofx":
        rows = parse_ofx(content)
    elif format == "csv":
        rows = parse_csv(content, {**DEFAULT_LAYOUT, **(csv_layout or {})})
    else:
        raise ana.Error("INVALID_FORMAT", "formato deve ser ofx ou csv")
    if not rows:
        raise ana.Error("EMPTY_STATEMENT", "nenhuma transação encontrada no arquivo")
    keyed = with_keys(rows)
    statement = ana.sql_value("INSERT INTO finance.bank_statement (bank_account, source, file_name, imported_by) "
                              "VALUES ($1, $2, $3, $4) RETURNING id", acc["code"], format, file_name, ana.context.user)
    inserted = 0
    for start in range(0, len(keyed), CHUNK):
        part = keyed[start:start + CHUNK]
        # ana:lint-ok sql_in_loop — one INSERT per batch of 5 000 lines (the batching itself)
        inserted += len(ana.sql(
            "INSERT INTO finance.bank_statement_line (statement_id, bank_account, posted_on, amount, description, document, "
            "  dedup_key) SELECT $1, $2, d, a::numeric, t, doc, k "
            "FROM unnest($3::date[], $4::text[], $5::text[], $6::text[], $7::text[]) AS x(d, a, t, doc, k) "
            "ON CONFLICT (bank_account, dedup_key) DO NOTHING RETURNING id",
            statement, acc["code"], [r["date"] for r in part], [str(r["amount"]) for r in part],
            [r["description"] for r in part], [r["document"] for r in part], [r["key"] for r in part]))
    duplicates = len(keyed) - inserted
    ana.sql_exec("UPDATE finance.bank_statement SET lines = $2, duplicates = $3 WHERE id = $1", statement, inserted, duplicates)
    ana.metrics([{"label": "Linhas novas", "value": inserted}, {"label": "Já importadas", "value": duplicates},
                 {"label": "Entradas", "value": f"R$ {sum(r['amount'] for r in rows if r['amount'] > 0):.2f}"},
                 {"label": "Saídas", "value": f"R$ {-sum(r['amount'] for r in rows if r['amount'] < 0):.2f}"}])
    if inserted:
        ana.actions([{"label": "Conciliar agora", "program": "finance.reconcile",
                      "params": {"bank_account": acc["code"]}, "style": "primary"}], title="Próximo passo")
    return {"statement": statement, "lines": inserted, "duplicates": duplicates}


def with_keys(rows):
    seen = {}
    out = []
    for r in rows:
        if r.get("id"):
            key = "id:" + r["id"]
        else:
            base = hashlib.sha256(f"{r['date']}|{r['amount']}|{r['description']}".encode()).hexdigest()[:40]
            n = seen.get(base, 0)
            seen[base] = n + 1
            key = f"h:{base}#{n}"
        out.append({**r, "key": key})
    return out


def amount_of(text, decimal_mark="."):
    t = str(text).strip().replace(" ", "")
    if decimal_mark == ",":
        t = t.replace(".", "").replace(",", ".")
    try:
        v = Decimal(t)
    except InvalidOperation:
        raise ana.Error("INVALID_AMOUNT", f"valor inválido no extrato: {text!r}") from None
    return v.quantize(Decimal("0.01"))


OFX_TRN = re.compile(r"<STMTTRN>(.*?)</STMTTRN>", re.S | re.I)
OFX_TAG = re.compile(r"<([A-Z0-9.]+)>([^<\r\n]*)", re.I)


def parse_ofx(content):
    rows = []
    for block in OFX_TRN.findall(content):
        f = {k.upper(): v.strip() for k, v in OFX_TAG.findall(block)}
        if not f.get("DTPOSTED") or not f.get("TRNAMT"):
            continue
        d = f["DTPOSTED"][:8]
        amount = amount_of(f["TRNAMT"].replace(",", "."))
        if amount == 0:
            continue
        rows.append({"date": datetime.date(int(d[:4]), int(d[4:6]), int(d[6:8])), "amount": amount,
                     "description": " ".join(x for x in (f.get("NAME", ""), f.get("MEMO", "")) if x)[:300],
                     "document": f.get("CHECKNUM") or f.get("REFNUM") or None, "id": f.get("FITID") or None})
    return rows


def parse_csv(content, layout):
    import csv
    import io
    rows = []
    reader = csv.reader(io.StringIO(content), delimiter=layout["delimiter"])
    for n, cols in enumerate(reader):
        if n < int(layout["skip"]) or not any(c.strip() for c in cols):
            continue

        def col(name):
            i = layout.get(name)
            return cols[int(i)].strip() if i is not None and int(i) < len(cols) else None
        try:
            date = datetime.datetime.strptime(col("date"), layout["date_format"]).date()
        except (TypeError, ValueError):
            raise ana.Error("INVALID_DATE", f"linha {n + 1}: data inválida {col('date')!r}") from None
        amount = amount_of(col("amount"), layout["decimal"])
        if amount == 0:
            continue
        rows.append({"date": date, "amount": amount, "description": (col("description") or "")[:300],
                     "document": col("document") or None, "id": col("id") or None})
    return rows
