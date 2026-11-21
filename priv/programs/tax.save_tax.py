# ana:description Cadastra ou altera um tributo: nome, ordem de cálculo, escopo e contas por papel
# ana:exposed yes
# ana:category Fiscal/Cadastros fiscais
"""Taxes are data (spec 049, D11, P21): a new tax is a row with its accounts by role, never a migration."""

from ana_lib.tax import admin, engine

ROLES = ("expense", "payable", "withheld", "credit", "credit_offset")
PARAMS = {
    "code": {"type": "str", "required": True, "label": "código (ex.: cbs)"},
    "name": {"type": "str", "required": True, "label": "nome"},
    "sequence": {"type": "int", "default": 100, "label": "ordem de cálculo"},
    "scope": {"type": "str", "default": "item", "label": "escopo",
              "choices": [["item", "Por item"], ["document", "No documento"]]},
    "roles": {"type": "dict", "label": "contas por papel ({\"expense\": \"tax_on_revenue\", \"payable\": \"2.1.7\"})"},
    "active": {"type": "bool", "default": True, "label": "ativo"},
}


def main(code, name, sequence=100, scope="item", roles=None, active=True):
    admin.require_tax()
    roles = roles or {}
    for k, v in roles.items():
        if k not in ROLES:
            raise ana.ParamError(f"papel desconhecido: {k} (use {', '.join(ROLES)})")
        if not engine.account(v):
            raise ana.ParamError(f"conta do papel {k} não encontrada: {v}")
    ana.sql_exec("INSERT INTO tax.tax (code, name, sequence, scope, roles, active, updated_by) "
                 "VALUES ($1, $2, $3, $4, $5::text::jsonb, $6, $7) ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, "
                 "sequence = EXCLUDED.sequence, scope = EXCLUDED.scope, roles = EXCLUDED.roles, active = EXCLUDED.active, "
                 "updated_at = now(), updated_by = EXCLUDED.updated_by",
                 code.strip().lower(), name, sequence, scope, engine.canonical(roles), active, ana.context.user)
    ana.actions([{"label": "Nova regra deste tributo", "program": "tax.save_rule", "params": {"tax": code}, "open": True}],
                title=f"Tributo {code} salvo")
    return {"tax": code}
