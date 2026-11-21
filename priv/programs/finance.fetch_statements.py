# ana:description Busca os extratos de todas as contas com fonte automática (pasta de arquivos ou API do banco) e concilia
# ana:exposed yes
# ana:role admin
# ana:category Financeiro/Conciliação bancária
"""T-017-05b. For every active source of finance.statement_source, each in its own savepoint (one bank failing
never stops the others):
- folder: every file of the folder not read yet (file and version) is imported — OFX or CNAB 240 told by the
  content — and remembered in finance.statement_file, so the same file never counts twice;
- api: the adapter program fetches the transactions since the last day fetched (one day of overlap: the import
  never duplicates) and the source moves on.
The import reconciles what is certain (spec 038). Source status, lines and errors stay on the source."""

import datetime

PARAMS = {"bank_account": {"type": "str", "label": "só esta conta (vazio = todas)",
                           "lookup": {"program": "finance.lookup", "params": {"kind": "bank_accounts"}}}}


def main(bank_account=None):
    sources = ana.sql("SELECT bank_account, kind, folder, connector, adapter, options, since FROM finance.statement_source "
                      "WHERE active AND ($1::text IS NULL OR bank_account = upper($1)) ORDER BY bank_account", bank_account)
    report = []
    for s in sources:
        try:
            with ana.savepoint():
                lines, files = (from_folder(s) if s["kind"] == "folder" else from_api(s))
            status = "ok"
        except ana.Error as e:
            lines, files, status = 0, 0, f"{e.code}: {e.message}"
        ana.sql_exec("UPDATE finance.statement_source SET last_run_at = now(), last_status = $2, last_lines = $3 WHERE bank_account = $1",
                     s["bank_account"], status, lines)
        report.append({"conta": s["bank_account"], "fonte": "pasta" if s["kind"] == "folder" else "API do banco",
                       "arquivos": files, "linhas novas": lines, "situação": status})
    ana.table(report, title="Extratos buscados")
    return {"sources": len(sources), "lines": sum(r["linhas novas"] for r in report),
            "failed": [r for r in report if r["situação"] != "ok"]}


def from_folder(s):
    folder = ana.files.folder(s["folder"])
    files = ana.files.list(folder).get("files") or []
    seen = {(r["file_id"], r["version"]) for r in ana.sql(
        "SELECT file_id, version FROM finance.statement_file WHERE file_id = ANY($1)", [f["id"] for f in files])}
    total, read = 0, 0
    for f in sorted(files, key=lambda x: x["id"]):
        version = f.get("version") or 1
        if (f["id"], version) in seen:
            continue
        got = ana.files.get(f["id"])
        try:
            text = got["data"].decode("utf-8")
        except UnicodeDecodeError:
            text = got["data"].decode("latin-1")            # CNAB files are often in ISO-8859-1
        is_csv = str(f.get("name") or "").lower().endswith(".csv")
        try:
            if not is_csv and not looks_like_statement(text):
                raise ana.Error("UNKNOWN_FORMAT", "o arquivo não é OFX nem CNAB 240 (CSV só com a extensão .csv)")
            with ana.savepoint():
                r = ana.call("finance.import_statement", bank_account=s["bank_account"], content=text,
                             format="csv" if is_csv else "auto", file_name=f.get("name"))
            ana.sql_exec("INSERT INTO finance.statement_file (file_id, version, bank_account, statement_id, status) "
                         "VALUES ($1, $2, $3, $4, 'imported')", f["id"], version, s["bank_account"], r["statement"])
            total += r["lines"]
        except ana.Error as e:
            if e.code == "EMPTY_STATEMENT":
                ana.sql_exec("INSERT INTO finance.statement_file (file_id, version, bank_account, status) "
                             "VALUES ($1, $2, $3, 'imported')", f["id"], version, s["bank_account"])
            else:
                ana.sql_exec("INSERT INTO finance.statement_file (file_id, version, bank_account, status, error) "
                             "VALUES ($1, $2, $3, 'failed', $4)", f["id"], version, s["bank_account"], f"{e.code}: {e.message}")
        read += 1
    return total, read


def looks_like_statement(text):
    head = text.lstrip()[:2000].upper()
    first = text.splitlines()[0].rstrip("\r\n") if text.splitlines() else ""
    return head.startswith("OFXHEADER") or "<OFX>" in head or (len(first) == 240 and first[7:8] == "0")


def from_api(s):
    today = datetime.date.today()
    since = s["since"] or (today - datetime.timedelta(days=30))
    got = ana.call(s["adapter"], connector=s["connector"], bank_account=s["bank_account"], since=since.isoformat(),
                   options=s["options"] or {})
    lines = 0
    params = {"bank_account": s["bank_account"], "file_name": f"API {s['connector']} desde {since:%d/%m/%Y}"}
    if got.get("closing_balance") is not None:
        params["closing_balance"] = str(got["closing_balance"])
        if got.get("closing_date"):
            params["closing_date"] = str(got["closing_date"])[:10]
    if got.get("format") == "lines" and got.get("lines"):
        lines = ana.call("finance.import_statement", format="lines", lines=got["lines"], **params)["lines"]
    elif got.get("format") == "ofx" and got.get("content"):
        try:
            lines = ana.call("finance.import_statement", format="ofx", content=got["content"], **params)["lines"]
        except ana.Error as e:
            if e.code != "EMPTY_STATEMENT":
                raise
    # One day of overlap: a transaction posted late on the last day is caught next time (the import deduplicates).
    ana.sql_exec("UPDATE finance.statement_source SET since = $2 WHERE bank_account = $1", s["bank_account"],
                 today - datetime.timedelta(days=1))
    return lines, 0
