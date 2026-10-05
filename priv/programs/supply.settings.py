# ana:description Parâmetros de compras: tolerância de recebimento, prazo de pagamento e alçadas
# ana:exposed yes
# ana:role admin
"""RNF-013-04 (P13). Without parameters, shows the current settings. Approval limit: role or
access group → maximum amount (empty = unlimited; remove_limit deletes it)."""

PARAMS = {
    "receipt_tolerance_pct": {"type": "decimal", "label": "tolerância de recebimento (%)"},
    "default_payment_days": {"type": "int", "label": "prazo de pagamento padrão (dias)"},
    "limit_kind": {"type": "str", "label": "alçada para", "choices": [["role", "Papel"], ["group", "Grupo de acesso"]]},
    "limit_target": {"type": "str", "label": "papel ou grupo"},
    "limit_amount": {"type": "decimal", "label": "valor máximo (vazio = sem limite)"},
    "remove_limit": {"type": "bool", "default": False, "label": "remover a alçada"},
}


def main(receipt_tolerance_pct=None, default_payment_days=None, limit_kind=None, limit_target=None, limit_amount=None,
         remove_limit=False):
    if receipt_tolerance_pct is not None or default_payment_days is not None:
        ana.sql_exec("UPDATE supply.policy SET receipt_tolerance_pct = COALESCE($1, receipt_tolerance_pct), "
                     "default_payment_days = COALESCE($2, default_payment_days) WHERE id = 1",
                     receipt_tolerance_pct, default_payment_days)
    if limit_kind or limit_target:
        if limit_kind not in ("role", "group") or not limit_target:
            raise ana.Error("INVALID_PARAMETER", "informe se a alçada é de papel ou grupo e qual")
        if remove_limit:
            ana.sql_exec("DELETE FROM supply.approval_limit WHERE target_kind = $1 AND target = $2", limit_kind, limit_target)
        else:
            ana.sql_exec("INSERT INTO supply.approval_limit (target_kind, target, max_amount) VALUES ($1, $2, $3) "
                         "ON CONFLICT (target_kind, target) DO UPDATE SET max_amount = EXCLUDED.max_amount",
                         limit_kind, limit_target, limit_amount)
    policy = ana.sql_one("SELECT receipt_tolerance_pct, default_payment_days FROM supply.policy WHERE id = 1")
    limits = ana.sql("SELECT CASE target_kind WHEN 'role' THEN 'papel' ELSE 'grupo' END AS tipo, target AS \"papel/grupo\", "
                     "COALESCE(max_amount::text, 'sem limite') AS \"valor máximo\" FROM supply.approval_limit ORDER BY 1, 2")
    ana.metrics([{"label": "Tolerância de recebimento", "value": f"{policy['receipt_tolerance_pct']}%"},
                 {"label": "Prazo de pagamento padrão", "value": f"{policy['default_payment_days']} dias"}])
    ana.table(limits, title="Alçadas de aprovação")
    return {"policy": policy, "limits": len(limits)}
