# ana:description Cadastra um atributo fiscal (de empresa, pessoa, item ou contrato) para usar nas regras
# ana:exposed yes
# ana:category Fiscal/Cadastros fiscais
"""Fiscal attributes are data (spec 049, D11): a new classification (a reform code, a benefit) is a row, not a
column. `source` reuses a column already in the registry (e.g. the regime of spec 043)."""

from ana_lib.tax import admin

TABLES = {"company": ("base", "company"), "party": ("base", "party"), "item": ("base", "product"),
          "contract": ("projects", "project")}
PARAMS = {
    "entity": {"type": "str", "required": True, "label": "de quem",
               "choices": [["company", "Empresa"], ["party", "Pessoa"], ["item", "Item"], ["contract", "Contrato/projeto"]]},
    "code": {"type": "str", "required": True, "label": "código (ex.: cclasstrib)"},
    "value_type": {"type": "str", "default": "text", "label": "tipo",
                   "choices": [["text", "Texto"], ["number", "Número"], ["boolean", "Sim/não"], ["date", "Data"]]},
    "description": {"type": "str", "label": "descrição"},
    "code_list": {"type": "str", "label": "lista de códigos válidos (opcional)"},
    "source": {"type": "str", "label": "coluna do cadastro que já guarda o valor (opcional)"},
}


def main(entity, code, value_type="text", description="", code_list=None, source=None):
    admin.require_tax()
    if source:
        schema, table = TABLES[entity]
        if not ana.sql_value("SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = $1 "
                             "AND table_name = $2 AND column_name = $3)", schema, table, source):
            raise ana.ParamError(f"o cadastro {schema}.{table} não tem a coluna {source}")
    ana.sql_exec("INSERT INTO tax.attribute (entity, code, value_type, code_list, source, description) "
                 "VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (entity, code) DO UPDATE SET value_type = EXCLUDED.value_type, "
                 "code_list = EXCLUDED.code_list, source = EXCLUDED.source, description = EXCLUDED.description",
                 entity, code.strip().lower(), value_type, code_list, source, description or "")
    ana.actions([{"label": "Informar valores", "program": "tax.set_attribute", "params": {"attribute": f"{entity}.{code}"},
                  "open": True}], title=f"Atributo {entity}.{code} salvo")
    return {"attribute": f"{entity}.{code}"}
