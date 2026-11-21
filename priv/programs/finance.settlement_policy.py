# ana:description Política de baixas: tolerância para juros/tarifas e compensação automática de créditos
# ana:exposed yes
# ana:role admin
# ana:category Financeiro/Contas a receber e a pagar
"""Spec 038 (RF-038-05). Within the tolerance a difference goes to interest received or bank fees; beyond it,
paying less leaves a residual bill and paying more becomes a credit of the party."""

PARAMS = {"tolerance": {"type": "decimal", "label": "tolerância (R$)"},
          "auto_offset": {"type": "bool", "label": "compensar créditos automaticamente"}}


def main(tolerance=None, auto_offset=None):
    if tolerance is not None or auto_offset is not None:
        if tolerance is not None and tolerance < 0:
            raise ana.Error("INVALID_VALUE", "a tolerância não pode ser negativa")
        ana.sql_exec("UPDATE finance.settlement_policy SET tolerance = COALESCE($1, tolerance), auto_offset = COALESCE($2, auto_offset), "
                     "updated_by = $3, updated_at = now() WHERE id = 1", tolerance, auto_offset, ana.context.user)
    return ana.sql_one("SELECT tolerance, auto_offset, updated_by, updated_at FROM finance.settlement_policy WHERE id = 1")
