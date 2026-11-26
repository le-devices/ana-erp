# ana:description Dados bancários do fornecedor: banco, agência, conta e chave PIX (sigilosos)
# ana:exposed yes
# ana:category Cadastros/Clientes, fornecedores e itens
# ana:menu no
"""Spec 068 (T-068-13, D10). The account a supplier is paid into. Branch, account and PIX key are secret: only an
administrator changes or sees them, the history records only that they changed (never the value) and a rule
"when the bank account of a supplier changes" (spec 068) can send the change to someone else to check."""

import re

PARAMS = {
    "party": {"type": "int", "required": True, "label": "fornecedor",
              "lookup": {"program": "supply.lookup", "params": {"kind": "suppliers"}}},
    "bank": {"type": "str", "required": True, "label": "banco (código de 3 dígitos)"},
    "branch": {"type": "str", "required": True, "label": "agência"},
    "account": {"type": "str", "required": True, "label": "conta (com dígito)"},
    "kind": {"type": "str", "default": "checking", "label": "tipo de conta",
             "choices": [["checking", "Corrente"], ["savings", "Poupança"], ["payment", "Pagamento"]]},
    "pix_key": {"type": "str", "label": "chave PIX"},
    "main": {"type": "bool", "default": False, "label": "conta principal"},
}


def _digits(v, pattern, what):
    v = re.sub(r"[\s.]", "", str(v or "")).upper()
    if not re.fullmatch(pattern, v):
        raise ana.Error("INVALID_VALUE", f"{what} inválido(a): {'use 3 dígitos' if what == 'banco' else 'só números e o dígito'}")
    return v


def main(party, bank, branch, account, kind="checking", pix_key=None, main=False):
    if ana.context.role != "admin":
        raise ana.Error("FORBIDDEN", "só o administrador altera dados bancários (são sigilosos)")
    if not ana.sql_one("SELECT 1 AS ok FROM base.party WHERE id = $1 AND kind IN ('supplier', 'both')", party):
        raise ana.Error("NOT_FOUND", "fornecedor não encontrado (o cadastro precisa ser fornecedor ou cliente e fornecedor)")
    bank = _digits(bank, r"[0-9]{3}", "banco")
    branch = _digits(branch, r"[0-9]{1,5}(-[0-9X])?", "agência")
    account = _digits(account, r"[0-9]{1,20}(-[0-9X])?", "conta")
    pix_key = (str(pix_key).strip() or None) if pix_key else None
    if kind not in ("checking", "savings", "payment"):
        raise ana.Error("INVALID_VALUE", "tipo de conta: corrente, poupança ou pagamento")
    if main:
        ana.sql_exec("UPDATE base.party_bank SET main = false WHERE party_id = $1 AND main "
                     "AND (bank, branch, account) <> ($2, $3, $4)", party, bank, branch, account)
    row = ana.sql_one(
        "INSERT INTO base.party_bank (party_id, bank, branch, account, kind, pix_key, main) VALUES ($1, $2, $3, $4, $5, $6, $7) "
        "ON CONFLICT (party_id, bank, branch, account) DO UPDATE SET kind = EXCLUDED.kind, pix_key = EXCLUDED.pix_key, "
        "  main = EXCLUDED.main RETURNING id, (xmax = 0) AS created",
        party, bank, branch, account, kind, pix_key, bool(main))
    ana.log("dados bancários " + ("incluídos" if row["created"] else "alterados") + f" no fornecedor {party}")
    return {"id": row["id"], "created": row["created"], "party": party}
