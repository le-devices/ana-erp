# ana:description Perfil de crédito do cliente: limite, tolerância de atraso, bloqueio automático e condições
# ana:exposed yes
"""RF-031-04. Empty limit = no limit; empty grace/auto block = the policy's. allowed_terms
restricts the terms the customer may use (empty = all active)."""

PARAMS = {
    "customer": {"type": "int", "required": True, "label": "cliente", "lookup": {"program": "sales.lookup", "params": {"kind": "customers"}}},
    "credit_limit": {"type": "decimal", "label": "limite de crédito (vazio = sem limite)"},
    "grace_days": {"type": "int", "label": "tolerância de atraso (dias; vazio = política)"},
    "auto_block": {"type": "bool", "label": "bloquear automaticamente por atraso"},
    "default_term": {"type": "str", "label": "condição padrão", "lookup": {"program": "finance.lookup", "params": {"kind": "payment_terms"}}},
    "allowed_terms": {"type": "list", "label": "condições permitidas (vazio = todas)", "add_label": "Adicionar condição", "columns": {
        "term": {"type": "str", "required": True, "label": "condição", "lookup": {"program": "finance.lookup", "params": {"kind": "payment_terms"}}}}},
}


def main(customer, credit_limit=None, grace_days=None, auto_block=None, default_term=None, allowed_terms=None):
    if not ana.sql_value("SELECT count(*) FROM base.party WHERE id = $1", customer):
        raise ana.Error("CUSTOMER_NOT_FOUND", f"cliente {customer} não encontrado")
    ana.sql_exec("INSERT INTO finance.credit_profile (party_id, credit_limit, grace_days, auto_block, default_term, updated_by) "
                 "VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (party_id) DO UPDATE SET credit_limit = EXCLUDED.credit_limit, "
                 "grace_days = EXCLUDED.grace_days, auto_block = EXCLUDED.auto_block, default_term = EXCLUDED.default_term, "
                 "updated_by = EXCLUDED.updated_by, updated_at = now()",
                 customer, credit_limit, grace_days, auto_block, default_term.upper() if default_term else None, ana.context.user)
    if allowed_terms is not None:
        ana.sql_exec("DELETE FROM finance.party_payment_term WHERE party_id = $1", customer)
        if allowed_terms:
            ana.sql_exec("INSERT INTO finance.party_payment_term (party_id, term) SELECT $1, upper(t) FROM unnest($2::text[]) t",
                         customer, [t["term"] if isinstance(t, dict) else str(t) for t in allowed_terms])   # grid rows or codes
    st = ana.sql_one("SELECT blocked, reason, open_amount, available FROM finance.credit_status($1, 0)", customer)
    return {"customer": customer, "blocked": st["blocked"], "reason": st["reason"], "available": st["available"]}
