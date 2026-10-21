# ana:description Importa extrato bancário (OFX, CNAB 240 ou CSV) sem duplicar lançamentos
# ana:exposed yes
# ana:command extrato
"""RF-017-06. Deduplication by the bank's transaction id (OFX FITID or a CSV id column) or,
without it, by a hash of date + amount + description (+ the occurrence number inside the file,
so two equal transactions on the same day are both kept). Lines go in batches of 5 000
(one INSERT … SELECT FROM unnest each, ON CONFLICT DO NOTHING).

T-017-05b: CNAB 240 (FEBRABAN bank statement: segment E transactions, batch trailer with the closing balance),
`auto` (the format is told by the content) and `lines` (transactions already read by a bank API adapter)."""

import datetime
import hashlib
import re
from decimal import Decimal, InvalidOperation

PARAMS = {
    "bank_account": {"type": "str", "required": True, "label": "conta bancária", "order": 1,
                     "lookup": {"program": "finance.lookup", "params": {"kind": "bank_accounts"}}},
    "format": {"type": "str", "default": "auto", "label": "formato", "order": 2,
               "choices": [["auto", "Reconhecer pelo conteúdo"], ["ofx", "OFX"], ["cnab240", "CNAB 240 (FEBRABAN)"],
                           ["csv", "CSV (planilha)"], ["lines", "Linhas (API do banco)"]]},
    "content": {"type": "str", "label": "conteúdo do arquivo", "order": 3},
    "lines": {"type": "list", "label": "transações já lidas (API): [{date, amount, description, document, id}]", "order": 9},
    "file_name": {"type": "str", "label": "nome do arquivo", "order": 4},
    "closing_balance": {"type": "decimal", "label": "saldo final do extrato (CSV; no OFX vem no arquivo)", "order": 6},
    "closing_date": {"type": "date", "label": "data do saldo final", "order": 7},
    "reconcile": {"type": "bool", "default": True, "label": "conciliar automaticamente ao importar", "order": 8},
    "csv_layout": {"type": "dict", "label": "layout do CSV", "order": 5,
                   "help": "colunas (a partir de 0): date, amount, description, document, id; delimiter; date_format; "
                           "decimal (',' ou '.'); skip (linhas de cabeçalho)"},
}
CHUNK = 5000
DEFAULT_LAYOUT = {"date": 0, "description": 1, "amount": 2, "document": None, "id": None,
                  "delimiter": ";", "date_format": "%d/%m/%Y", "decimal": ",", "skip": 1}


def main(bank_account, content=None, format="auto", file_name=None, csv_layout=None, closing_balance=None, closing_date=None,
         reconcile=True, lines=None):
    acc = ana.sql_one("SELECT code FROM finance.bank_account WHERE code = $1 AND active", bank_account.strip().upper())
    if not acc:
        raise ana.Error("BANK_ACCOUNT_NOT_FOUND", f"conta bancária {bank_account} não encontrada")
    if format != "lines" and not (content or "").strip():
        raise ana.Error("INVALID_PARAMETER", "informe o conteúdo do arquivo")
    if format == "auto":
        format = detect(content)
    if format == "lines":
        rows = parse_lines(lines or [])
    elif format == "cnab240":
        rows, bal = parse_cnab240(content)
        if closing_balance is None and bal:
            closing_balance, closing_date = bal
    elif format == "ofx":
        rows = parse_ofx(content)
    elif format == "csv":
        rows = parse_csv(content, {**DEFAULT_LAYOUT, **(csv_layout or {})})
    else:
        raise ana.Error("INVALID_FORMAT", "formato deve ser auto, ofx, cnab240, csv ou lines")
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
    if format == "ofx" and closing_balance is None:
        closing_balance, closing_date = ofx_balance(content)
    if closing_balance is not None:
        closing_date = closing_date or max(r["date"] for r in rows)
    ana.sql_exec("UPDATE finance.bank_statement SET lines = $2, duplicates = $3, closing_balance = $4, closing_date = $5 WHERE id = $1",
                 statement, inserted, duplicates, closing_balance, closing_date)
    ana.metrics([{"label": "Linhas novas", "value": inserted}, {"label": "Já importadas", "value": duplicates},
                 {"label": "Entradas", "value": f"R$ {sum(r['amount'] for r in rows if r['amount'] > 0):.2f}"},
                 {"label": "Saídas", "value": f"R$ {-sum(r['amount'] for r in rows if r['amount'] < 0):.2f}"}])
    result = None
    if inserted and reconcile:
        # Spec 038 (RF-038-06): what is certain is reconciled at once; the rest waits in the workbench.
        result = ana.call("finance.reconcile", bank_account=acc["code"])
    if inserted:
        ana.actions([{"label": "Abrir a conciliação", "program": "finance.reconciliation",
                      "params": {"bank_account": acc["code"]}, "style": "primary", "open": True}], title="Próximo passo")
    return {"statement": statement, "format": format, "lines": inserted, "duplicates": duplicates, "closing_balance": closing_balance,
            "reconciled": result and {k: result[k] for k in ("settled", "linked", "payouts", "rules", "transfers") if k in result}}


def detect(content):
    """ofx, cnab240 or csv, from the content itself (files dropped in a folder come without a declared format)."""
    head = content.lstrip()[:2000]
    if head.upper().startswith("OFXHEADER") or "<OFX>" in head.upper():
        return "ofx"
    first = content.splitlines()[0] if content.splitlines() else ""
    if len(first.rstrip("\r\n")) == 240 and first[7:8] == "0" and first[:3].isdigit():
        return "cnab240"
    return "csv"


def parse_lines(items):
    """Transactions from a bank API adapter: [{date, amount, description?, document?, id?}]."""
    rows = []
    for t in items:
        try:
            day = t["date"] if isinstance(t["date"], datetime.date) else datetime.date.fromisoformat(str(t["date"])[:10])
        except (KeyError, ValueError):
            raise ana.Error("INVALID_LINE", f"transação sem data válida: {t!r}") from None
        amount = amount_of(t.get("amount"))
        if amount == 0:
            continue
        rows.append({"date": day, "amount": amount, "description": str(t.get("description") or "")[:300],
                     "document": (str(t["document"]) if t.get("document") else None), "id": (str(t["id"]) if t.get("id") else None)})
    return rows


def _cnab_date(s):
    s = s.strip()
    if not s or set(s) == {"0"}:
        return None
    return datetime.date(int(s[4:8]), int(s[2:4]), int(s[0:2]))


def parse_cnab240(content):
    """FEBRABAN CNAB 240 bank statement: segment E (record 3) carries each transaction — posting date 146-153
    (DDMMAAAA), amount 154-171 (2 decimals), D/C 172, history 180-204, document 205-240; the batch trailer
    (record 5) the closing balance — date 143-150, amount 151-168, D/C 169. Returns (rows, (balance, date) | None)."""
    rows, balance = [], None
    for n, raw in enumerate(content.splitlines(), start=1):
        line = raw.rstrip("\r\n")
        if not line.strip():
            continue
        if len(line) < 240:
            raise ana.Error("INVALID_FILE", f"CNAB 240: a linha {n} tem {len(line)} posições (esperado 240)")
        kind = line[7]
        if kind == "3" and line[13] == "E":
            sign = -1 if line[171] == "D" else 1
            try:
                day = _cnab_date(line[145:153]) or _cnab_date(line[137:145])
                amount = (Decimal(line[153:171]) / 100 * sign).quantize(Decimal("0.01"))
            except (ValueError, InvalidOperation):
                raise ana.Error("INVALID_FILE", f"CNAB 240: data ou valor inválido na linha {n}") from None
            if amount == 0 or day is None:
                continue
            rows.append({"date": day, "amount": amount, "description": line[179:204].strip(),
                         "document": line[204:240].strip() or None, "id": None})
        elif kind == "5":
            try:
                day = _cnab_date(line[142:150])
                value = Decimal(line[150:168]) / 100 * (-1 if line[168] == "D" else 1)
            except (ValueError, InvalidOperation):
                continue
            if day:
                balance = (value.quantize(Decimal("0.01")), day)
    return rows, balance


def ofx_balance(content):
    """<LEDGERBAL><BALAMT>…<DTASOF>… of the OFX: (balance, date) or (None, None)."""
    block = re.search(r"<LEDGERBAL>(.*?)(?:</LEDGERBAL>|<AVAILBAL>|</STMTRS>|$)", content, re.S | re.I)
    if not block:
        return None, None
    amt = re.search(r"<BALAMT>\s*([-0-9.,]+)", block.group(1), re.I)
    day = re.search(r"<DTASOF>\s*(\d{8})", block.group(1), re.I)
    if not amt:
        return None, None
    try:
        bal = Decimal(amt.group(1).replace(",", "."))
    except InvalidOperation:
        return None, None
    return bal, (datetime.datetime.strptime(day.group(1), "%Y%m%d").date() if day else None)


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
