# SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Quality gate inspection (spec 064, phase 1) without a database: rules by category, acceptance in the code,
fingerprints, and the product's own programs through the gate (RF-064-09, CA-064-06).

Run: python3 -m unittest tests/runtime/test_quality.py
"""

import ast
import glob
import importlib.util
import os
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_spec = importlib.util.spec_from_file_location("ana_runtime_q", os.path.join(ROOT, "priv", "python", "ana_runtime.py"))
rt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rt)


def lint(source):
    return rt.lint_program(ast.parse(source), source)


def rules(source):
    return sorted((f["line"], f["rule"], f["severity"]) for f in lint(source))


class Rules(unittest.TestCase):
    """RF-064-01: security, performance, robustness, standards and disk."""

    def test_ca_064_01_fstring_sql_with_received_value_is_serious_with_suggestion(self):
        f = lint("def main(name):\n    return ana.sql(f\"SELECT id FROM base.party WHERE name = '{name}' LIMIT 1\")\n")
        sql = [x for x in f if x["rule"] == "dynamic_sql"]
        self.assertEqual((sql[0]["line"], sql[0]["severity"], sql[0]["category"]), (2, "serious", "security"))
        self.assertIn("$1", sql[0]["suggestion"])

    def test_security_rules(self):
        got = rules("import subprocess\n"
                    "API_TOKEN = 'abc123secretvalue'\n"
                    "def main(x):\n"
                    "    eval(x)\n"
                    "    open('/etc/passwd')\n"
                    "    ana.log(f'token {api_token}')\n")
        self.assertIn((1, "forbidden_import", "serious"), got)
        self.assertIn((2, "hardcoded_secret", "critical"), got)
        self.assertIn((4, "eval_exec", "critical"), got)
        self.assertIn((5, "file_access", "serious"), got)
        self.assertIn((6, "sensitive_output", "serious"), got)

    def test_robustness_rules(self):
        got = rules("def main():\n"
                    "    try:\n"
                    "        x = 1\n"
                    "    except Exception:\n"
                    "        pass\n"
                    "    while True:\n"
                    "        x += 1\n"
                    "    raise ValueError('ruim')\n"
                    "    ana.sql_exec('DELETE FROM s.t')\n")
        self.assertIn((4, "swallowed_exception", "serious"), got)
        self.assertIn((6, "endless_loop", "serious"), got)
        self.assertIn((8, "generic_error", "warning"), got)
        self.assertIn((9, "no_where", "critical"), got)

    def test_standards_and_disk_rules(self):
        got = rules('PARAMS = {"a": {"type": "int"}}\n'
                    "def main(a, ids):\n"
                    "    raise ana.Error('pedido não encontrado', 'x')\n"
                    "    for i in ids:\n"
                    "        ana.sql_exec('INSERT INTO s.t (id) VALUES ($1)', i)\n"
                    "        ana.http('erp', '/x')\n"
                    "    # a BAPI do outro sistema\n")
        self.assertIn((1, "param_label", "info"), got)
        self.assertIn((3, "error_code", "warning"), got)
        self.assertIn((5, "write_in_loop", "warning"), got)
        self.assertIn((6, "external_in_loop", "warning"), got)
        self.assertIn((7, "foreign_terms", "warning"), got)

    def test_good_code_has_no_findings(self):
        self.assertEqual(lint('PARAMS = {"a": {"type": "int", "label": "número"}}\n'
                              "def main(a):\n"
                              "    try:\n"
                              "        r = ana.sql_one('SELECT id FROM s.t WHERE id = $1', a)\n"
                              "    except ana.Error as e:\n"
                              "        ana.log(f'falhou: {e.code}')\n"
                              "        raise\n"
                              "    if not r:\n"
                              "        raise ana.Error('NOT_FOUND', f'registro {a} não encontrado')\n"
                              "    ana.sql_batch('INSERT INTO s.t (id) VALUES ($1)', [[a]])\n"
                              "    return r\n"), [])

    def test_acceptance_in_the_code_and_stable_fingerprint(self):
        src = ("def main():\n"
               "    # ana:lint-ok eval_exec — expressão vem de constante revisada\n"
               "    eval('1 + 1')\n"
               "    eval('2 + 2')\n")
        self.assertEqual([(f["line"], f["rule"]) for f in lint(src)], [(4, "eval_exec")])
        a = lint("def main():\n    eval('2 + 2')\n")[0]["fingerprint"]
        b = lint("# comentário novo\n\n\ndef main():\n    eval('2 + 2')\n")[0]["fingerprint"]
        self.assertEqual(a, b)                                            # the line moved; same finding

    def test_rnf_064_01_thousand_lines_fast(self):
        body = "".join(f"    x{i} = ana.sql_one('SELECT id FROM s.t WHERE id = $1', {i})\n" for i in range(1000))
        src = "def main():\n" + body
        t = time.perf_counter()
        lint(src)
        self.assertLess((time.perf_counter() - t) * 1000, 200 * 3)        # 200 ms on a developer machine; slack for CI


class ProductThroughTheGate(unittest.TestCase):
    """RF-064-09, CA-064-06: the product's programs have no serious or critical finding (or a reasoned acceptance)."""

    def test_ca_064_06_product_programs_pass_the_gate(self):
        bad = []
        for path in sorted(glob.glob(os.path.join(ROOT, "priv", "programs", "*.py"))):
            with open(path, encoding="utf-8") as fh:
                src = fh.read()
            for f in lint(src):
                if rt.SEVERITY_ORDER[f["severity"]] >= rt.SEVERITY_ORDER["serious"]:
                    bad.append(f"{os.path.basename(path)}:{f['line']} {f['rule']} — {f['message']}")
        self.assertEqual(bad, [])

    def test_every_acceptance_has_a_reason(self):
        bad = []
        for path in sorted(glob.glob(os.path.join(ROOT, "priv", "programs", "*.py"))):
            with open(path, encoding="utf-8") as fh:
                text = fh.read().splitlines()
            for n, line in enumerate(text, start=1):
                if "ana:lint-ok" in line and not any(sep in line.split("ana:lint-ok", 1)[1] for sep in ("—", " - ")):
                    bad.append(f"{os.path.basename(path)}:{n}")
        self.assertEqual(bad, [])


if __name__ == "__main__":
    unittest.main()
