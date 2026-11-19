# ana:description Pacote de regras de exemplo: Simples Nacional (anexos III e V, fator R), ISS e retenções de serviços — conferir com o contador
# ana:kind library
"""Example rule package for service companies in Brazil (spec 049, D5, D9, D10, D11).

Pure data: taxes, fiscal attributes, indicators, tables, rules and test cases. The engine knows none of
these names (P21); a change in the law is a new version of this package (a product update, spec 028),
applied with `tax.apply_package` after the company's test cases run.

CONFERIR COM O CONTADOR: values follow Lei Complementar 123/2006 (anexos III e V, from 2018) and the usual
withholding rules for services; the company's tax officer validates them before use.
"""

NAME = "br_services"
VERSION = "2026.11.2"
TITLE = "Serviços no Brasil: Simples Nacional (anexos III e V, fator R), ISS e retenções"
NOTICE = "Pacote de exemplo do produto — conferir com o contador antes de usar."

ATTRIBUTES = [
    # entity, code, type, source column in the registry, description
    {"entity": "company", "code": "regime", "value_type": "text", "source": "tax_regime",
     "description": "Regime tributário da empresa (com vigência quando muda)"},
    {"entity": "party", "code": "regime", "value_type": "text", "source": "tax_regime",
     "description": "Regime tributário da pessoa"},
    {"entity": "party", "code": "withholds_iss", "value_type": "boolean", "source": None,
     "description": "Tomador obrigado pela lei do município a reter o ISS"},
    {"entity": "contract", "code": "service_code", "value_type": "text", "source": None,
     "description": "Item da lista de serviços (LC 116) do contrato"},
    {"entity": "contract", "code": "simples_annex", "value_type": "text", "source": None,
     "description": "Anexo do Simples da atividade: III, IV, V ou fator_r"},
    {"entity": "item", "code": "service_code", "value_type": "text", "source": None,
     "description": "Item da lista de serviços (LC 116)"},
    {"entity": "item", "code": "simples_annex", "value_type": "text", "source": None,
     "description": "Anexo do Simples da atividade: III, IV, V ou fator_r"},
    {"entity": "item", "code": "ncm", "value_type": "text", "source": None, "description": "NCM da mercadoria"},
    {"entity": "item", "code": "nbs", "value_type": "text", "source": None, "description": "NBS do serviço"},
]

INDICATORS = [
    {"code": "rbt12", "kind": "account_sum", "description": "Receita bruta dos 12 meses anteriores (RBT12)",
     "definition": {"account_prefixes": ["4.1"], "side": "credit", "months": 12, "start_rule": "annualize",
                    "include_document": True}},
    {"code": "payroll12", "kind": "account_sum", "description": "Folha de salários dos 12 meses anteriores, com pró-labore e encargos",
     "definition": {"account_prefixes": ["5.5"], "side": "debit", "months": 12, "start_rule": "annualize"}},
    {"code": "fator_r", "kind": "formula", "description": "Fator R: folha ÷ receita dos 12 meses",
     "definition": {"expression": "round(indicator('payroll12') / indicator('rbt12'), 4) if indicator('rbt12') > 0 else 0",
                    "watch": {"threshold": "0.28", "margin": "0.02",
                              "message": "fator R perto de 28%: abaixo disso as atividades com fator R vão para o anexo V"}}},
]

TAXES = [
    {"code": "simples", "name": "Simples Nacional (DAS)", "sequence": 10, "scope": "item",
     "roles": {"expense": "tax_on_revenue", "payable": "simples_payable"}},
    {"code": "iss_simples_wh", "name": "ISS retido de prestador do Simples", "sequence": 20, "scope": "item",
     "roles": {"withheld": "simples_payable"}},
    {"code": "iss", "name": "ISS", "sequence": 30, "scope": "item",
     "roles": {"expense": "tax_on_revenue", "payable": "iss_payable", "withheld": "iss_payable"}},
    {"code": "irrf_wh", "name": "IRRF retido", "sequence": 40, "scope": "document", "roles": {"withheld": "federal_withheld"}},
    {"code": "pis_wh", "name": "PIS retido", "sequence": 41, "scope": "document", "roles": {"withheld": "federal_withheld"}},
    {"code": "cofins_wh", "name": "COFINS retida", "sequence": 42, "scope": "document", "roles": {"withheld": "federal_withheld"}},
    {"code": "csll_wh", "name": "CSLL retida", "sequence": 43, "scope": "document", "roles": {"withheld": "federal_withheld"}},
]

# Progressive brackets: key "<annex>/<order>", value = upper limit of the RBT12, data = nominal rate, deduction
# and the ISS share inside the effective rate (LC 123, anexos III e V).
_III = [("180000", "0.06", "0", "0.335"), ("360000", "0.112", "9360", "0.32"), ("720000", "0.135", "17640", "0.325"),
        ("1800000", "0.16", "35640", "0.325"), ("3600000", "0.21", "125640", "0.335"), ("4800000", "0.33", "648000", "0")]
_V = [("180000", "0.155", "0", "0.14"), ("360000", "0.18", "4500", "0.17"), ("720000", "0.195", "9900", "0.19"),
      ("1800000", "0.205", "17100", "0.21"), ("3600000", "0.23", "62100", "0.235"), ("4800000", "0.305", "540000", "0")]
TABLES = [
    {"table_name": "simples_bracket", "key": f"{annex}/{n}", "valid_from": "2018-01-01", "value": lim,
     "data": {"nominal": nom, "deduction": ded, "iss_share": iss}}
    for annex, rows in (("III", _III), ("V", _V)) for n, (lim, nom, ded, iss) in enumerate(rows, start=1)
]

_SIMPLES_ANNEX = [
    ["annex_cfg", "item.simples_annex if has('item.simples_annex') else contract.simples_annex"],
    ["annex", "('III' if indicator('fator_r') >= 0.28 else 'V') if annex_cfg == 'fator_r' else annex_cfg"],
    ["rbt", "indicator('rbt12')"],
]
_SERVICE = ["service_sale", "service_sale_return"]
_NOT_SIMPLES = ["presumed", "real", "simples_excess", "nonprofit"]
_PCC_LIMIT = "10"

RULES = [
    {"key": "simples-services", "tax": "simples", "name": "Simples Nacional sobre serviços — alíquota efetiva da faixa",
     "valid_from": "2018-01-01",
     "criteria": {"emitter.regime": "simples", "doc.operation": _SERVICE},
     "formulas": _SIMPLES_ANNEX + [
         ["nominal", "bracket('simples_bracket', annex, rbt, 'nominal')"],
         ["deduction", "bracket('simples_bracket', annex, rbt, 'deduction')"],
         ["rate", "round((rbt * nominal - deduction) / rbt, 6) if rbt > 0 else nominal"],
         ["base", "amount"],
         ["amount", "round(base * rate, 2)"]]},
    {"key": "iss-simples-withheld", "tax": "iss_simples_wh",
     "name": "ISS retido pelo tomador de prestador do Simples — parcela do ISS na alíquota efetiva (mín. 2%, máx. 5%)",
     "valid_from": "2018-01-01",
     "criteria": {"emitter.regime": "simples", "recipient.withholds_iss": True, "doc.operation": _SERVICE},
     "formulas": [
         ["share", "bracket('simples_bracket', tax('simples', 'annex'), indicator('rbt12'), 'iss_share')"],
         ["rate", "min(max(round(tax('simples', 'rate') * share, 4), 0.02), 0.05)"],
         ["base", "amount"],
         ["withheld", "round(base * rate, 2)"]]},
    {"key": "iss-own", "tax": "iss", "name": "ISS do prestador fora do Simples — alíquota do município",
     "valid_from": "2018-01-01",
     "criteria": {"emitter.regime": _NOT_SIMPLES, "doc.operation": _SERVICE},
     "formulas": [
         ["rate", "table('iss_city', emitter.uf + '/' + emitter.city)"],
         ["base", "amount"],
         ["amount", "round(base * rate, 2)"],
         ["withheld", "amount if recipient.withholds_iss == True else 0"]]},
    {"key": "irrf-services", "tax": "irrf_wh", "name": "IRRF 1,5% retido por pessoa jurídica (serviços profissionais)",
     "valid_from": "2018-01-01",
     "criteria": {"emitter.regime": _NOT_SIMPLES, "recipient.person_kind": "company", "doc.operation": "service_sale"},
     "formulas": [["base", "amount"], ["rate", "0.015"], ["value", "round(base * rate, 2)"],
                  ["applies", "value > 10"], ["withheld", "value"]]},
] + [
    {"key": f"{code}-services", "tax": code, "name": f"{label} retido por pessoa jurídica (serviços)",
     "valid_from": "2018-01-01",
     "criteria": {"emitter.regime": _NOT_SIMPLES, "recipient.person_kind": "company", "doc.operation": "service_sale"},
     "formulas": [["base", "amount"], ["rate", rate], ["applies", f"round(base * 0.0465, 2) > {_PCC_LIMIT}"],
                  ["withheld", "round(base * rate, 2)"]]}
    for code, label, rate in (("pis_wh", "PIS 0,65%", "0.0065"), ("cofins_wh", "COFINS 3%", "0.03"), ("csll_wh", "CSLL 1%", "0.01"))
]

# Test cases shipped with the package: indicators fixed so the expected values do not depend on the books.
CASES = [
    {"key": "simples-fator-r-iii", "name": "P&D por empresa do Simples com fator R ≥ 28% (anexo III, 2ª faixa)",
     "document": {"operation": "service_sale", "date": "2026-11-19",
                  "emitter": {"regime": "simples"}, "recipient": {"person_kind": "company", "regime": "real"},
                  "items": [{"description": "Horas de P&D", "quantity": 10, "unit_price": "1000.00",
                             "attributes": {"simples_annex": "fator_r"}}],
                  "indicators": {"rbt12": "300000", "payroll12": "90000", "fator_r": "0.3"}},
     "expected": {"taxes": {"simples": {"amount": "808.00"}}, "totals": {"withheld": "0.00"}}},
    {"key": "simples-fator-r-v", "name": "P&D por empresa do Simples com fator R abaixo de 28% (anexo V, 2ª faixa)",
     "document": {"operation": "service_sale", "date": "2026-11-19",
                  "emitter": {"regime": "simples"}, "recipient": {"person_kind": "company", "regime": "real"},
                  "items": [{"description": "Horas de P&D", "quantity": 10, "unit_price": "1000.00",
                             "attributes": {"simples_annex": "fator_r"}}],
                  "indicators": {"rbt12": "300000", "payroll12": "60000", "fator_r": "0.2"}},
     "expected": {"taxes": {"simples": {"amount": "1650.00"}}, "totals": {"withheld": "0.00"}}},
    {"key": "simples-iss-withheld", "name": "Tomador que retém ISS de prestador do Simples (anexo III, 1ª faixa)",
     "document": {"operation": "service_sale", "date": "2026-11-19",
                  "emitter": {"regime": "simples"},
                  "recipient": {"person_kind": "company", "regime": "real", "withholds_iss": True},
                  "items": [{"description": "Projeto de firmware", "quantity": 1, "unit_price": "10000.00",
                             "attributes": {"simples_annex": "III"}}],
                  "indicators": {"rbt12": "120000", "payroll12": "0", "fator_r": "0"}},
     "expected": {"taxes": {"simples": {"amount": "600.00"}, "iss_simples_wh": {"withheld": "201.00"}},
                  "totals": {"withheld": "201.00"}}},
]
