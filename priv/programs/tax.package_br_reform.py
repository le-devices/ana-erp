# ana:description Pacote de regras de exemplo: reforma tributária — CBS e IBS na transição 2026–2033, créditos nas compras — conferir com o contador
# ana:kind library
"""Example rule package for the tax reform (spec 049, phase 3, T-049-09, CA-049-07; D11/P21).

It enters with no migration and no program change: taxes, attributes, codes, tables by year, rules and test
cases are data. The engine knows none of these names.

- 2026: test year — CBS 0.9% and IBS 0.1% highlighted on the document (informational, offset against
  PIS/COFINS): nothing is charged or posted.
- 2027–2028: CBS at the reference rate minus 0.1 point and IBS at 0.1% (0.05% state + 0.05% city), charged
  on top of the price ("por fora"); credits on purchases from regular-regime suppliers.
- 2029–2032: IBS grows as ICMS and ISS fall (9/10, 8/10, 7/10, 6/10); 2033: full IBS.
- Simples Nacional: CBS and IBS stay inside the DAS unless the company opts to pay them outside
  (attribute emitter.reform_option = "regular"), which gives its customers full credit.

CONFERIR COM O CONTADOR: the reference rates from 2027 depend on resolutions of the Senate; the values marked
"estimated" in the tables are placeholders and the tax watch warns while they are in use. The base excludes
ISS and ICMS during the transition; reduced-rate classes (cClassTrib) are added to the reform_class table.
"""

NAME = "br_reform"
VERSION = "2026.11.1"
TITLE = "Reforma tributária: CBS e IBS na transição (2026–2033), créditos nas compras"
NOTICE = ("Pacote de exemplo do produto — conferir com o contador. Alíquotas de referência a partir de 2027 são "
          "estimadas até a resolução do Senado.")

ACCOUNTS = [
    {"code": "5.1.6", "description": "Créditos de tributos sobre compras", "nature": "expense",
     "cost_center_policy": "optional", "key": "purchase_tax_credits",
     "key_description": "Créditos de tributos sobre compras (redução do custo)"},
]

ATTRIBUTES = [
    {"entity": "company", "code": "regime", "value_type": "text", "source": "tax_regime",
     "description": "Regime tributário da empresa (com vigência quando muda)"},
    {"entity": "company", "code": "reform_option", "value_type": "text", "source": None,
     "description": "Empresa do Simples: 'regular' recolhe CBS e IBS fora do DAS (crédito integral aos clientes)"},
    {"entity": "party", "code": "regime", "value_type": "text", "source": "tax_regime",
     "description": "Regime tributário da pessoa"},
    {"entity": "party", "code": "reform_option", "value_type": "text", "source": None,
     "description": "Fornecedor do Simples que recolhe CBS e IBS fora do DAS ('regular')"},
    {"entity": "item", "code": "cclasstrib", "value_type": "text", "code_list": "cclasstrib", "source": None,
     "description": "Classificação tributária da reforma (cClassTrib)"},
    {"entity": "contract", "code": "cclasstrib", "value_type": "text", "code_list": "cclasstrib", "source": None,
     "description": "Classificação tributária da reforma (cClassTrib) dos serviços do contrato"},
]

CODES = [
    {"list": "cclasstrib", "code": "000001", "description": "Situações tributadas integralmente pelo IBS e CBS",
     "valid_from": "2026-01-01"},
]

_EST = {"estimated": True, "note": "alíquota de referência estimada; aguarda resolução do Senado — confirme o valor oficial"}
TABLES = [
    # key: tax; value: rate in force in the period
    {"table_name": "reform_rate", "key": "cbs", "valid_from": "2026-01-01", "valid_to": "2026-12-31", "value": "0.009",
     "data": {"phase": "teste"}},
    {"table_name": "reform_rate", "key": "ibs", "valid_from": "2026-01-01", "valid_to": "2026-12-31", "value": "0.001",
     "data": {"phase": "teste"}},
    {"table_name": "reform_rate", "key": "cbs", "valid_from": "2027-01-01", "valid_to": "2028-12-31", "value": "0.087",
     "data": {**_EST, "phase": "CBS cheia (referência menos 0,1 ponto)"}},
    {"table_name": "reform_rate", "key": "ibs", "valid_from": "2027-01-01", "valid_to": "2028-12-31", "value": "0.001",
     "data": {"phase": "IBS em teste (0,05% estadual + 0,05% municipal)"}},
    {"table_name": "reform_rate", "key": "cbs", "valid_from": "2029-01-01", "value": "0.088", "data": _EST},
    {"table_name": "reform_rate", "key": "ibs", "valid_from": "2029-01-01", "valid_to": "2029-12-31", "value": "0.0177", "data": _EST},
    {"table_name": "reform_rate", "key": "ibs", "valid_from": "2030-01-01", "valid_to": "2030-12-31", "value": "0.0354", "data": _EST},
    {"table_name": "reform_rate", "key": "ibs", "valid_from": "2031-01-01", "valid_to": "2031-12-31", "value": "0.0531", "data": _EST},
    {"table_name": "reform_rate", "key": "ibs", "valid_from": "2032-01-01", "valid_to": "2032-12-31", "value": "0.0708", "data": _EST},
    {"table_name": "reform_rate", "key": "ibs", "valid_from": "2033-01-01", "value": "0.177", "data": _EST},
    # cClassTrib → reduction of the rate and CST (add the reduced classes the company uses)
    {"table_name": "reform_class", "key": "000001", "valid_from": "2026-01-01", "value": "0",
     "data": {"reduction": "0", "cst": "000"}},
]

TAXES = [
    {"code": "cbs", "name": "CBS", "sequence": 60, "scope": "item",
     "roles": {"expense": "tax_on_revenue", "payable": "revenue_tax_payable", "credit": "tax_recoverable",
               "credit_offset": "purchase_tax_credits"}},
    {"code": "ibs", "name": "IBS", "sequence": 61, "scope": "item",
     "roles": {"expense": "tax_on_revenue", "payable": "revenue_tax_payable", "credit": "tax_recoverable",
               "credit_offset": "purchase_tax_credits"}},
]

_SALES = ["service_sale", "sale"]
_REGULAR = ["presumed", "real", "simples_excess", "nonprofit"]


def _sale(key, extra=None):
    """Formulas of a sale: class and reduction, base without ISS/ICMS, rate of the year."""
    return [
        ["cclasstrib", "item.cclasstrib if has('item.cclasstrib') else (contract.cclasstrib if has('contract.cclasstrib') else '000001')"],
        ["reduction", "table('reform_class', cclasstrib, 'reduction')"],
        ["cst", "table('reform_class', cclasstrib, 'cst')"],
        ["base", "amount - tax('iss', 'amount') - tax('icms', 'amount')"],
        ["rate", f"round(table('reform_rate', '{key}') * (1 - reduction), 6)"],
    ] + (extra or [])


def _rules(key):
    name = key.upper()
    return [
        {"key": f"{key}-test-year", "tax": key, "valid_from": "2026-01-01", "valid_to": "2026-12-31",
         "name": f"{name} 2026: destacada no documento, sem cobrança (ano de teste)",
         "criteria": {"doc.operation": _SALES, "emitter.regime": _REGULAR},
         "formulas": _sale(key, [["highlighted", "round(base * rate, 2)"], ["amount", "0"]])},
        {"key": f"{key}-regular", "tax": key, "valid_from": "2027-01-01",
         "name": f"{name} cobrada além do preço (regime regular)",
         "criteria": {"doc.operation": _SALES, "emitter.regime": _REGULAR},
         "formulas": _sale(key, [["charged", "round(base * rate, 2)"]])},
        {"key": f"{key}-simples-outside-das", "tax": key, "valid_from": "2027-01-01",
         "name": f"{name} cobrada além do preço (Simples que recolhe fora do DAS)",
         "criteria": {"doc.operation": _SALES, "emitter.regime": "simples", "emitter.reform_option": "regular"},
         "formulas": _sale(key, [["charged", "round(base * rate, 2)"]])},
        {"key": f"{key}-credit", "tax": key, "valid_from": "2027-01-01",
         "name": f"Crédito de {name} na compra de fornecedor do regime regular",
         "criteria": {"doc.operation": "purchase", "emitter.regime": _REGULAR},
         "formulas": [
             ["regular_supplier", "recipient.regime in ('presumed', 'real', 'simples_excess', 'nonprofit') "
                                  "or recipient.reform_option == 'regular'"],
             ["all_rates", "table('reform_rate', 'cbs') + table('reform_rate', 'ibs')"],
             ["rate", f"table('reform_rate', '{key}')"],
             ["base", "round(amount / (1 + all_rates), 2)"],
             ["credit", "round(base * rate, 2) if regular_supplier else 0"]]},
    ]


RULES = _rules("cbs") + _rules("ibs")

CASES = [
    {"key": "reform-2026-test-year", "name": "Venda em 2026 (lucro presumido): CBS e IBS só destacadas",
     "document": {"operation": "sale", "date": "2026-11-19", "emitter": {"regime": "presumed"},
                  "recipient": {"person_kind": "company", "regime": "real"},
                  "items": [{"description": "Placa de controle", "amount": "10000.00"}]},
     "expected": {"taxes": {"cbs": {"amount": "0.00"}, "ibs": {"amount": "0.00"}}, "totals": {"charged": "0.00"}}},
    {"key": "reform-2027-regular", "name": "Venda em 2027 (lucro presumido): CBS e IBS cobradas além do preço",
     "document": {"operation": "sale", "date": "2027-02-01", "emitter": {"regime": "presumed"},
                  "recipient": {"person_kind": "company", "regime": "real"},
                  "items": [{"description": "Placa de controle", "amount": "10000.00"}]},
     "expected": {"taxes": {"cbs": {"charged": "870.00"}, "ibs": {"charged": "10.00"}}, "totals": {"charged": "880.00"}}},
    {"key": "reform-2027-simples-das", "name": "Serviço em 2027 por empresa do Simples dentro do DAS: nada cobrado à parte",
     "document": {"operation": "service_sale", "date": "2027-02-01", "emitter": {"regime": "simples"},
                  "recipient": {"person_kind": "company", "regime": "real"},
                  "items": [{"description": "Horas de P&D", "amount": "10000.00", "attributes": {"simples_annex": "III"}}],
                  "indicators": {"rbt12": "120000", "payroll12": "0", "fator_r": "0"}},
     "expected": {"totals": {"charged": "0.00"}}},
    {"key": "reform-2027-credit", "name": "Compra em 2027 de fornecedor do lucro real: crédito de CBS e IBS",
     "document": {"operation": "purchase", "date": "2027-02-01", "emitter": {"regime": "presumed"},
                  "recipient": {"person_kind": "company", "regime": "real"},
                  "items": [{"description": "Componentes", "amount": "1088.00"}]},
     "expected": {"taxes": {"cbs": {"credit": "87.00"}, "ibs": {"credit": "1.00"}}, "totals": {"credit": "88.00"}}},
]
