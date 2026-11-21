# ana:description Cadastra conta bancária (ligada a uma conta contábil) para extratos e conciliação
# ana:role admin
# ana:category Financeiro/Conciliação bancária
"""Spec 017. The ledger account must be a postable asset account."""

PARAMS = {
    "code": {"type": "str", "required": True, "label": "código"},
    "name": {"type": "str", "required": True, "label": "nome"},
    "account": {"type": "str", "required": True, "label": "conta contábil", "lookup": {"program": "finance.lookup", "params": {"kind": "accounts"}}},
    "bank": {"type": "str", "label": "banco"},
    "branch": {"type": "str", "label": "agência"},
    "number": {"type": "str", "label": "conta"},
    "active": {"type": "bool", "default": True, "label": "ativa"},
}


def main(code, name, account, bank=None, branch=None, number=None, active=True):
    code = code.strip().upper()
    acc = ana.sql_one("SELECT nature, postable FROM finance.account WHERE code = $1", account)
    if not acc or acc["nature"] != "asset" or not acc["postable"]:
        raise ana.Error("INVALID_ACCOUNT", "a conta contábil deve ser de ativo e aceitar lançamentos")
    ana.sql_exec("INSERT INTO finance.bank_account (code, name, account, bank, branch, number, active) "
                 "VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, "
                 "account = EXCLUDED.account, bank = EXCLUDED.bank, branch = EXCLUDED.branch, number = EXCLUDED.number, "
                 "active = EXCLUDED.active", code, name, account, bank, branch, number, active)
    return {"code": code}
