# ana:description Adaptador genérico de extrato por API: busca as transações da conta num endpoint JSON ou OFX
# ana:menu no
"""T-017-05b. The default adapter of a bank statement source of kind "api" (finance.statement_sources). Calls the
connector (spec 017: allowed hosts, credentials, retries) with GET <path>?account=<account>&from=<since> and
accepts either JSON — {"transactions": [{"id", "date", "amount", "description", "document"}],
"balance": {"amount", "date"}} — or an OFX document. Each bank with another contract gets an adapter of its own
(a program of the company, same parameters and answer); the fetch routine does not change.

Answer: {"format": "lines" | "ofx", "lines" | "content", "closing_balance", "closing_date"}."""

PARAMS = {
    "connector": {"type": "str", "required": True, "label": "conector do banco"},
    "bank_account": {"type": "str", "required": True, "label": "conta bancária"},
    "since": {"type": "date", "label": "transações a partir de"},
    "options": {"type": "dict", "label": "opções (path, account)"},
}


def main(connector, bank_account, since=None, options=None):
    opts = options or {}
    params = {"account": opts.get("account") or bank_account}
    if since:
        params["from"] = since.isoformat()
    r = ana.http(connector, "GET", opts.get("path", "/statement"), params=params)
    if not r.ok:
        raise ana.Error("BANK_API_FAILED", f"o banco respondeu HTTP {r['status']}")
    if "json" in r:
        body = r["json"] or {}
        bal = body.get("balance") or {}
        return {"format": "lines", "lines": list(body.get("transactions") or []),
                "closing_balance": bal.get("amount"), "closing_date": bal.get("date")}
    text = r.get("text") or ""
    if "<OFX>" not in text.upper():
        raise ana.Error("BANK_API_FAILED", "resposta do banco não é JSON nem OFX")
    return {"format": "ofx", "content": text}
