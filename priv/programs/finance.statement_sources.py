# ana:description Fontes automáticas de extrato: por conta bancária, pasta de arquivos (OFX ou CNAB 240) ou API do banco
# ana:exposed yes
# ana:role admin
# ana:command extratos_fontes
# ana:category Financeiro/Conciliação bancária
"""T-017-05b. Without parameters: each bank account with its source, last fetch and result. With bank_account and
kind: configures the source — "folder" (files OFX or CNAB 240 sent to a folder of the file repository, by anyone
or any system; default /Extratos/<account>) or "api" (connector of the bank + adapter program; the generic one
reads JSON or OFX). `remove` turns the account back to manual import only. The routine "extratos.buscar" (or
"Buscar agora") reads every source."""

PARAMS = {
    "bank_account": {"type": "str", "label": "conta bancária", "lookup": {"program": "finance.lookup", "params": {"kind": "bank_accounts"}}},
    "kind": {"type": "str", "label": "fonte", "choices": [["folder", "Pasta de arquivos (OFX ou CNAB 240)"], ["api", "API do banco"]]},
    "folder": {"type": "str", "label": "pasta (vazio = /Extratos/<conta>)"},
    "connector": {"type": "str", "label": "conector do banco (API)"},
    "adapter": {"type": "str", "label": "programa adaptador (vazio = genérico)"},
    "account_at_bank": {"type": "str", "label": "conta no banco, como o banco a identifica (API)"},
    "path": {"type": "str", "label": "caminho do extrato na API (vazio = /statement)"},
    "since": {"type": "date", "label": "buscar a partir de (API; vazio = 30 dias)"},
    "active": {"type": "bool", "default": True, "label": "ativa"},
    "remove": {"type": "bool", "default": False, "label": "voltar a importar só à mão"},
}


def main(bank_account=None, kind=None, folder=None, connector=None, adapter=None, account_at_bank=None, path=None,
         since=None, active=True, remove=False):
    if bank_account:
        code = bank_account.strip().upper()
        if not ana.sql_value("SELECT count(*) FROM finance.bank_account WHERE code = $1", code):
            raise ana.Error("BANK_ACCOUNT_NOT_FOUND", f"conta bancária {code} não encontrada")
        if remove:
            ana.sql_exec("DELETE FROM finance.statement_source WHERE bank_account = $1", code)
        elif kind:
            if kind == "folder":
                folder = (folder or f"/Extratos/{code}").strip()
                ana.files.folder(folder)                          # created now, ready to receive files
                values = ("folder", folder, None, None, {})
            elif kind == "api":
                if not connector:
                    raise ana.Error("INVALID_PARAMETER", "informe o conector do banco (Integrações → Conectores)")
                adapter = (adapter or "finance.bank_api_generic").strip()
                if not ana.sql_value("SELECT count(*) FROM bpm.program_names() AS n WHERE n = $1", adapter):
                    raise ana.Error("INVALID_PARAMETER", f"programa adaptador {adapter} inexistente ou inativo")
                opts = {k: v for k, v in (("account", account_at_bank), ("path", path)) if v}
                values = ("api", None, connector.strip(), adapter, opts)
            else:
                raise ana.Error("INVALID_PARAMETER", "fonte deve ser folder ou api")
            ana.sql_exec(
                "INSERT INTO finance.statement_source (bank_account, kind, folder, connector, adapter, options, since, active, updated_by) "
                "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) ON CONFLICT (bank_account) DO UPDATE SET kind = EXCLUDED.kind, "
                "folder = EXCLUDED.folder, connector = EXCLUDED.connector, adapter = EXCLUDED.adapter, options = EXCLUDED.options, "
                "since = COALESCE(EXCLUDED.since, finance.statement_source.since), active = EXCLUDED.active, "
                "updated_by = EXCLUDED.updated_by, updated_at = now()", code, *values, since, active, ana.context.user)
    rows = ana.sql(
        "SELECT a.code, a.name, s.kind, s.folder, s.connector, s.adapter, s.active, s.last_run_at, s.last_status, s.last_lines, "
        "  (SELECT count(*) FROM finance.statement_file f WHERE f.bank_account = a.code AND f.status = 'failed') AS failed_files "
        "FROM finance.bank_account a LEFT JOIN finance.statement_source s ON s.bank_account = a.code WHERE a.active ORDER BY a.code")
    ana.table([{"conta": r["code"], "nome": r["name"],
                "fonte": {"folder": f"pasta {r['folder']}", "api": f"API ({r['connector']}, {r['adapter']})"}.get(r["kind"], "manual"),
                "situação": ("desligada" if r["kind"] and not r["active"] else r["last_status"] or ("ainda não buscou" if r["kind"] else "—")),
                "última busca": r["last_run_at"], "linhas novas": r["last_lines"], "arquivos com erro": r["failed_files"] or 0,
                "_actions": ([{"label": "Buscar agora", "program": "finance.fetch_statements", "params": {"bank_account": r["code"]}}]
                             if r["kind"] else []) +
                            [{"label": "Usar pasta de arquivos", "program": "finance.statement_sources",
                              "params": {"bank_account": r["code"], "kind": "folder"}},
                             {"label": "Usar API do banco", "program": "finance.statement_sources",
                              "params": {"bank_account": r["code"], "kind": "api"},
                              "ask": {"connector": {"type": "str", "required": True, "label": "conector do banco"},
                                      "account_at_bank": {"type": "str", "label": "conta no banco"}}}]}
               for r in rows], title="Fontes automáticas de extrato")
    ana.actions([{"label": "Buscar todos os extratos agora", "program": "finance.fetch_statements", "style": "primary"}],
                title="Pasta: envie os arquivos OFX ou CNAB 240 pela área Arquivos para a pasta da conta — a busca lê cada arquivo uma vez")
    return {"sources": [{k: r[k] for k in ("code", "kind", "folder", "connector", "adapter", "active", "last_status")} for r in rows]}
