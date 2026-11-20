"""Tax engine without a database (spec 049): formula language, selection, Simples package, validity.

The libraries are loaded straight from priv/programs. Run: python3 -m unittest tests/runtime/test_tax.py
"""

import datetime
import os
import re
import sys
import types
import unittest
from decimal import Decimal

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROGRAMS = os.path.join(ROOT, "priv", "programs")


def _load(name):
    mod_name = "ana_lib." + name
    if mod_name in sys.modules:
        return sys.modules[mod_name]
    for pkg in ("ana_lib", "ana_lib.tax"):
        if pkg not in sys.modules:
            p = types.ModuleType(pkg)
            p.__path__ = []
            sys.modules[pkg] = p
    m = types.ModuleType(mod_name)
    with open(os.path.join(PROGRAMS, name + ".py"), encoding="utf-8") as f:
        src = f.read()
    sys.modules[mod_name] = m
    exec(compile(src, name, "exec"), m.__dict__)
    setattr(sys.modules["ana_lib.tax"], name.split(".")[1], m)
    return m


fx = _load("tax.formula")
engine = _load("tax.engine")
package = _load("tax.package_br_services")
D = Decimal


def package_data(extra_rules=(), extra_taxes=(), extra_tables=(), values=()):
    rules = [{**r, "id": i, "version": 1, "status": "active"} for i, r in enumerate(package.RULES, start=1)]
    rules += [{"version": 1, "status": "active", **r} for r in extra_rules]
    return engine.Data(taxes=list(package.TAXES) + list(extra_taxes), rules=rules,
                       tables=list(package.TABLES) + list(extra_tables), attributes=package.ATTRIBUTES,
                       values=list(values), indicators=package.INDICATORS)


def normalized(document):
    """What normalize() builds from the registry, here from the document itself."""
    items = []
    for it in document["items"]:
        q, p = D(str(it.get("quantity", 1))), D(str(it.get("unit_price", 0)))
        items.append({"amount": D(str(it["amount"])) if "amount" in it else q * p, "quantity": q, "unit_price": p,
                      "discount": D(0), "attributes": dict(it.get("attributes", {}))})
    return {"date": document["date"], "doc": {"operation": document["operation"]},
            "emitter": dict(document.get("emitter", {})), "recipient": dict(document.get("recipient", {})),
            "contract": dict(document.get("contract", {})), "items": items}


def run(document, data=None, indicators=None):
    data = data or package_data()
    ind = {k: D(v) for k, v in (indicators or document.get("indicators") or {}).items()}
    return engine.compute(normalized(document), data, lambda c: ind[c])


class FormulaLanguage(unittest.TestCase):
    """RF-049-04, CA-049-05: closed language, validated when saved."""

    def test_company_value_in_a_formula(self):
        """Spec 065 (T-065-07): company_value('nome') reads a company value on the date of the fact."""
        c = fx.validate([["rate", "company_value('financeiro.aliquota_extra') / 100"], ["amount", "1000 * rate"]])
        out = fx.evaluate(c, {}, {"company_value": lambda name: D("5") if name == "financeiro.aliquota_extra" else None})
        self.assertEqual(out["amount"], D("50"))
        with self.assertRaises(fx.FormulaError):
            fx.validate([["amount", "company_value(rate)"], ["rate", "1"]])           # the name goes between quotes

    def test_ca_049_05_free_code_and_unknown_functions_are_refused(self):
        for bad, why in [("__import__('os').system('x')", "função desconhecida"),
                         ("open('/etc/passwd')", "função desconhecida"),
                         ("amount.real", "nome desconhecido"),
                         ("(1).real", "caminhos do documento"),
                         ("item['x']", "não permitida"),
                         ("(lambda: 1)()", "função desconhecida"),
                         ("[x for x in (1, 2)]", "não permitida"),
                         ("round(amount, ndigits=2)", "por posição"),
                         ("amount ** 2", "operador não permitido"),
                         ("mystery.field", "nome desconhecido"),
                         ("amount +", "sintaxe inválida")]:
            with self.subTest(bad=bad):
                with self.assertRaises(fx.FormulaError) as e:
                    fx.validate([["amount", bad]])
                self.assertIn(why, e.exception.message)

    def test_error_names_the_formula_and_the_position(self):
        with self.assertRaises(fx.FormulaError) as e:
            fx.validate([["base", "amount"], ["rate", "0.05"], ["amount", "round(base * rate, 2) + foo(1)"]])
        self.assertEqual(e.exception.formula, "amount")
        self.assertIn("posição", e.exception.text())

    def test_decimal_exact_rounding_and_order(self):
        c = fx.validate([["a", "0.1 + 0.2"], ["b", "round(2.675, 2)"], ["c", "floor(2.679, 2)"],
                         ["amount", "a + b + c"]])
        out = fx.evaluate(c, {}, {})
        self.assertEqual((out["a"], out["b"], out["c"], out["amount"]), (D("0.3"), D("2.68"), D("2.67"), D("5.65")))

    def test_text_conditions_lists_and_paths(self):
        c = fx.validate([["k", "emitter.uf + '/' + emitter.city"],
                         ["amount", "1 if recipient.kind in ('company', 'public') and not doc.same_city else 0"]])
        out = fx.evaluate(c, {"emitter.uf": "SP", "emitter.city": "campinas", "recipient.kind": "company",
                              "doc.same_city": False}, {})
        self.assertEqual((out["k"], out["amount"]), ("SP/campinas", D(1)))

    def test_division_by_zero_and_missing_value_are_clear(self):
        with self.assertRaises(fx.FormulaError) as e:
            fx.evaluate(fx.validate([["amount", "1 / (amount - amount)"]]), {"amount": D(5)}, {})
        self.assertIn("divisão por zero", e.exception.message)
        with self.assertRaises(fx.FormulaError) as e:
            fx.evaluate(fx.validate([["amount", "recipient.rate * 2"]]), {}, {})
        self.assertIn("valor ausente", e.exception.message)

    def test_rule_needs_an_output(self):
        with self.assertRaises(fx.FormulaError):
            fx.validate([["base", "amount"]])


class Selection(unittest.TestCase):
    """RF-049-03, CA-049-03: the most specific rule wins; a tie is an error."""

    def rule(self, i, criteria, rate):
        return {"id": i, "tax": "t", "name": f"r{i}", "status": "active", "valid_from": "2020-01-01",
                "criteria": criteria, "formulas": [["amount", f"round(amount * {rate}, 2)"]], "version": 1}

    def data(self, *rules):
        return engine.Data(taxes=[{"code": "t", "name": "T", "scope": "item", "roles": {}}], rules=rules)

    def doc(self, **item_attrs):
        return {"date": "2026-11-19", "operation": "x", "emitter": {"uf": "SP"},
                "items": [{"amount": "100", "attributes": item_attrs}]}

    def test_most_specific_rule_wins(self):
        d = self.data(self.rule(1, {}, "0.01"), self.rule(2, {"emitter.uf": "SP"}, "0.02"),
                      self.rule(3, {"emitter.uf": "SP", "item.ncm": {"prefix": "85"}}, "0.03"),
                      self.rule(4, {"emitter.uf": "SP", "item.ncm": {"prefix": "8542"}}, "0.04"))
        self.assertEqual(run(self.doc(ncm="85423190"), d)["totals"]["amount"], D("4.00"))
        self.assertEqual(run(self.doc(ncm="85011000"), d)["totals"]["amount"], D("3.00"))
        self.assertEqual(run(self.doc(ncm="90000000"), d)["totals"]["amount"], D("2.00"))

    def test_ca_049_03_tie_is_a_conflict(self):
        r1, r2 = self.rule(1, {"emitter.uf": "SP"}, "0.01"), self.rule(2, {"item.ncm": {"prefix": "8"}}, "0.02")
        r2["criteria"] = {"emitter.uf": ["SP", "RJ"]}
        with self.assertRaises(engine.TaxError) as e:
            run(self.doc(), self.data(r1, r2))
        self.assertEqual(e.exception.code, "TAX_RULE_CONFLICT")
        self.assertEqual([o["id"] for o in engine.conflicts(r1, [r1, r2])], [2])
        r3 = self.rule(3, {"emitter.uf": "RJ"}, "0.03")
        self.assertEqual(engine.conflicts(r3, [r1]), [])                 # never match the same document
        r4 = self.rule(4, {"emitter.uf": "SP"}, "0.04")
        r4["valid_from"], r1["valid_to"] = "2027-01-01", "2026-12-31"
        self.assertEqual(engine.conflicts(r4, [r1]), [])                 # consecutive validity


class SimplesPackage(unittest.TestCase):
    """D10, CA-049-08: the Simples, the fator R and the withheld ISS are only data of the package."""

    def test_ca_049_08_package_cases(self):
        for case in package.CASES:
            with self.subTest(case=case["key"]):
                r = run(case["document"])
                by = {t["tax"]: t for t in r["taxes"]}
                for tax, fields in case["expected"]["taxes"].items():
                    for k, v in fields.items():
                        self.assertEqual(by[tax][k], D(v), (tax, k, r["explanation"]))
                for k, v in case["expected"].get("totals", {}).items():
                    self.assertEqual(r["totals"][k], D(v))

    def test_ca_049_08_no_federal_withholding_for_simples_provider(self):
        doc = dict(package.CASES[0]["document"])
        r = run(doc)
        self.assertEqual({t["tax"] for t in r["taxes"]}, {"simples"})

    def test_federal_withholding_for_presumed_provider_with_minimum(self):
        base = {"operation": "service_sale", "date": "2026-11-19", "emitter": {"regime": "presumed", "uf": "SP", "city": "campinas"},
                "recipient": {"person_kind": "company", "regime": "real", "withholds_iss": True},
                "items": [{"quantity": 1, "unit_price": "10000.00"}]}
        tables = [{"table_name": "iss_city", "key": "SP/campinas", "valid_from": "2020-01-01", "value": "0.05"}]
        r = run(base, package_data(extra_tables=tables), {})
        by = {t["tax"]: t for t in r["taxes"]}
        self.assertEqual((by["iss"]["amount"], by["iss"]["withheld"]), (D("500.00"), D("500.00")))
        self.assertEqual((by["irrf_wh"]["withheld"], by["pis_wh"]["withheld"], by["cofins_wh"]["withheld"],
                          by["csll_wh"]["withheld"]), (D("150.00"), D("65.00"), D("300.00"), D("100.00")))
        self.assertEqual(r["net"], D("8885.00"))
        small = dict(base, items=[{"quantity": 1, "unit_price": "200.00"}])
        r = run(small, package_data(extra_tables=tables), {})
        self.assertEqual({t["tax"] for t in r["taxes"]}, {"iss"})          # retentions under the minimum
        self.assertTrue(r["explanation"])

    def test_brackets_follow_rbt12(self):
        doc = package.CASES[2]["document"]
        rates = {}
        for rbt in ("100000", "200000", "500000", "1000000", "2000000"):
            r = run(doc, indicators={"rbt12": rbt, "payroll12": "0", "fator_r": "0"})
            rates[rbt] = next(t for t in r["taxes"] if t["tax"] == "simples")["rate"]
        self.assertEqual(rates["100000"], D("0.06"))
        self.assertEqual(rates["200000"], D("0.0652"))                   # (200000 × 0,112 − 9360) ÷ 200000
        self.assertTrue(rates["100000"] < rates["200000"] < rates["500000"] < rates["1000000"] < rates["2000000"])


class Validity(unittest.TestCase):
    """CA-049-02 and CA-049-09: dates decide rules, tables and attributes; a new tax is only data."""

    def test_ca_049_02_future_rate_does_not_change_today(self):
        tables = [{"table_name": "rate_by_year", "key": "x", "valid_from": "2026-01-01", "valid_to": "2026-12-31", "value": "0.009"},
                  {"table_name": "rate_by_year", "key": "x", "valid_from": "2027-01-01", "value": "0.088"}]
        taxes = [{"code": "newtax", "name": "Tributo novo", "sequence": 50, "scope": "item",
                  "roles": {"expense": "tax_on_revenue", "payable": "x"}}]
        rules = [{"id": 900, "tax": "newtax", "name": "novo", "valid_from": "2026-01-01", "criteria": {"item.newclass": "A"},
                  "formulas": [["rate", "table('rate_by_year', 'x')"], ["base", "amount"], ["amount", "round(base * rate, 2)"]]}]
        data = package_data(extra_rules=rules, extra_taxes=taxes, extra_tables=tables)
        doc = {"operation": "service_sale", "emitter": {"regime": "mei"}, "items": [{"amount": "1000", "attributes": {"newclass": "A"}}]}
        r26 = run({**doc, "date": "2026-11-19"}, data, {})
        r27 = run({**doc, "date": "2027-01-04"}, data, {})
        self.assertEqual(next(t for t in r26["taxes"] if t["tax"] == "newtax")["amount"], D("9.00"))
        self.assertEqual(next(t for t in r27["taxes"] if t["tax"] == "newtax")["amount"], D("88.00"))

    def test_ca_049_09_regime_change_by_date(self):
        values = [{"entity": "company", "entity_id": "1", "attribute": "regime", "value": "simples",
                   "valid_from": "2026-01-01", "valid_to": "2026-12-31"},
                  {"entity": "company", "entity_id": "1", "attribute": "regime", "value": "presumed",
                   "valid_from": "2027-01-01"}]
        data = package_data(values=values)
        a26 = engine.attributes_of(data, "company", 1, {"id": 1, "tax_regime": "real"}, datetime.date(2026, 6, 1))
        a27 = engine.attributes_of(data, "company", 1, {"id": 1, "tax_regime": "real"}, datetime.date(2027, 6, 1))
        a25 = engine.attributes_of(data, "company", 1, {"id": 1, "tax_regime": "real"}, datetime.date(2025, 6, 1))
        self.assertEqual((a25["regime"], a26["regime"], a27["regime"]), ("real", "simples", "presumed"))


reform = _load("tax.package_br_reform")


def both_packages(extra_tables=()):
    rules, i = [], 1
    for pkg in (package, reform):
        for r in pkg.RULES:
            rules.append({**r, "id": i, "version": 1, "status": "active"})
            i += 1
    attrs = {(a["entity"], a["code"]): a for a in package.ATTRIBUTES + reform.ATTRIBUTES}
    return engine.Data(taxes=package.TAXES + reform.TAXES, rules=rules, tables=package.TABLES + reform.TABLES + list(extra_tables),
                       attributes=list(attrs.values()), indicators=package.INDICATORS)


class Reform(unittest.TestCase):
    """Phase 3 (T-049-09, CA-049-07): CBS and IBS of the transition enter only as a package (P21)."""

    def check(self, case, r):
        by = {t["tax"]: t for t in r["taxes"]}
        for tax, fields in case["expected"].get("taxes", {}).items():
            for k, v in fields.items():
                self.assertEqual(by[tax][k], D(v), (case["key"], tax, k, r["explanation"]))
        for k, v in case["expected"].get("totals", {}).items():
            self.assertEqual(r["totals"][k], D(v), (case["key"], k))

    def test_ca_049_07_package_cases(self):
        for case in reform.CASES:
            with self.subTest(case=case["key"]):
                self.check(case, run(case["document"], both_packages()))

    def test_ca_049_07_2026_highlighted_2027_charged(self):
        doc = dict(reform.CASES[0]["document"])
        r26 = run(doc, both_packages(), {})
        r27 = run({**doc, "date": "2027-02-01"}, both_packages(), {})
        cbs26 = r26["items"][0]["taxes"]
        out = {t["tax"]: t["outputs"] for t in cbs26}
        self.assertEqual((out["cbs"]["highlighted"], out["ibs"]["highlighted"]), (D("90.00"), D("10.00")))
        self.assertEqual((r26["totals"]["charged"], r26["net"]), (D("0.00"), D("10000.00")))
        self.assertEqual((r27["totals"]["charged"], r27["net"]), (D("880.00"), D("10880.00")))   # added to the price
        self.assertEqual(out["cbs"]["cst"], "000")
        lines = engine.postings(r27, both_packages())
        self.assertEqual(sorted((a, d, c) for a, d, c, _ in lines),
                         [("revenue_tax_payable", D(0), D("10.00")), ("revenue_tax_payable", D(0), D("870.00"))])
        r29 = run({**doc, "date": "2029-03-01"}, both_packages(), {})
        self.assertEqual({t["tax"]: t["charged"] for t in r29["taxes"]}, {"cbs": D("880.00"), "ibs": D("177.00")})

    def test_base_excludes_iss_and_reduced_class(self):
        tables = [{"table_name": "iss_city", "key": "SP/campinas", "valid_from": "2020-01-01", "value": "0.05"},
                  {"table_name": "reform_class", "key": "RED60", "valid_from": "2026-01-01", "value": "0",
                   "data": {"reduction": "0.6", "cst": "200"}}]
        doc = {"operation": "service_sale", "date": "2027-02-01", "emitter": {"regime": "presumed", "uf": "SP", "city": "campinas"},
               "recipient": {"person_kind": "individual"},
               "items": [{"amount": "1000.00", "attributes": {"cclasstrib": "RED60"}}]}
        r = run(doc, both_packages(tables), {})
        by = {t["tax"]: t for t in r["taxes"]}
        self.assertEqual(by["iss"]["amount"], D("50.00"))
        self.assertEqual(by["cbs"]["base"], D("950.00"))                                  # without the ISS
        self.assertEqual(by["cbs"]["charged"], D("33.06"))                                # 950 × 8,7% × 40%

    def test_credit_only_from_regular_supplier(self):
        doc = dict(reform.CASES[3]["document"])
        self.assertEqual(run(doc, both_packages(), {})["totals"]["credit"], D("88.00"))
        simples = {**doc, "recipient": {"regime": "simples"}}
        self.assertEqual(run(simples, both_packages(), {})["totals"]["credit"], D("0.00"))
        opted = {**doc, "recipient": {"regime": "simples", "reform_option": "regular"}}
        self.assertEqual(run(opted, both_packages(), {})["totals"]["credit"], D("88.00"))

    def test_rule_for_one_contract_beats_general_rules(self):
        r_general = {"id": 1, "tax": "t", "name": "geral", "status": "active", "valid_from": "2020-01-01",
                     "criteria": {"emitter.regime": "real", "doc.operation": "service_sale"}, "formulas": [["amount", "1"]]}
        r_contract = {"id": 2, "tax": "t", "name": "contrato", "status": "active", "valid_from": "2020-01-01",
                      "criteria": {"contract.code": "P1", "doc.operation": "service_sale"}, "formulas": [["amount", "2"]]}
        self.assertEqual(engine.conflicts(r_contract, [r_general]), [])
        env = {"emitter.regime": "real", "doc.operation": "service_sale", "contract.code": "P1"}
        self.assertEqual(engine.choose([r_general, r_contract], env, datetime.date(2026, 1, 1))["id"], 2)

    def test_p21_reform_needs_no_migration(self):
        migrations = sorted(os.listdir(os.path.join(ROOT, "priv", "migrations")))
        text = "".join(open(os.path.join(ROOT, "priv", "migrations", m), encoding="utf-8").read().lower()
                       for m in migrations if m > "064")
        self.assertNotIn("cbs", text)
        self.assertNotIn("ibs", text)


class NoLawInCode(unittest.TestCase):
    """RNF-049-05 (P21): the engine and the language never name a tax, a regime or a rate."""

    WORDS = r"\b(iss|icms|ipi|pis|cofins|csll|irrf|inss|cbs|ibs|simples|presumed|mei|das|fator_r|rbt12)\b"

    def test_rnf_049_05_engine_is_generic(self):
        for name in ("tax.engine", "tax.formula"):
            with open(os.path.join(PROGRAMS, name + ".py"), encoding="utf-8") as f:
                src = f.read().lower()
            found = sorted(set(re.findall(self.WORDS, src)))
            self.assertEqual(found, [], name)


class NoTaxOutsideTheEngine(unittest.TestCase):
    """RNF-049-04: product programs never multiply by a tax rate; taxes come from tax.engine."""

    PATTERN = re.compile(r"(\*\s*[\w.\[\]\"']*(tax_rate|iss_rate|_tax_pct)\b)|(\b(tax_rate|iss_rate)[\w\[\]\"']*\s*\*)"
                         r"|\b(icms|ipi|pis|cofins|csll|irrf|inss|cbs|ibs)_?(rate|aliq\w*)\b")

    def test_rnf_049_04_no_tax_calculation_outside_the_engine(self):
        bad = []
        for name in sorted(os.listdir(PROGRAMS)):
            if not name.endswith(".py") or name.startswith("tax."):
                continue
            with open(os.path.join(PROGRAMS, name), encoding="utf-8") as f:
                for n, line in enumerate(f, start=1):
                    if self.PATTERN.search(line) and not line.lstrip().startswith("#"):
                        bad.append(f"{name}:{n}: {line.strip()}")
        self.assertEqual(bad, [])


if __name__ == "__main__":
    unittest.main()
