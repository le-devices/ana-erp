# SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Company values (spec 065) in the Python runtime, without a database: ana.value() hands the value in its type and
a selection answers `x in sel` with the same rule as base.company_value_matches() in SQL (RF-065-05, D1).

Run: python3 -m unittest tests/runtime/test_company_values.py
"""

import datetime
import decimal
import importlib.util
import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_spec = importlib.util.spec_from_file_location("ana_runtime_cv", os.path.join(ROOT, "priv", "python", "ana_runtime.py"))
rt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rt)


def value(v, kind, shape="single"):
    return rt.company_value({"value": v, "type": kind, "shape": shape})


class Typed(unittest.TestCase):
    def test_each_type_arrives_in_its_python_type(self):
        self.assertEqual(value("18.5", "decimal"), decimal.Decimal("18.5"))
        self.assertEqual(value(7, "integer"), 7)
        self.assertEqual(value("2026-11-20", "date"), datetime.date(2026, 11, 20))
        self.assertIs(value(True, "boolean"), True)
        self.assertEqual(value("2026-11", "month"), "2026-11")
        self.assertEqual(value(["PD1", "PD2"], "reference", "list"), ["PD1", "PD2"])
        self.assertEqual(value(["1", "2.5"], "decimal", "list"), [decimal.Decimal("1"), decimal.Decimal("2.5")])
        self.assertIsNone(value(None, "decimal"))


class Selections(unittest.TestCase):
    def test_ranges_prefixes_and_exclusions(self):
        s = value({"ranges": [["4000", "4999"]], "exclude": ["4500"], "prefixes": ["3.1"]}, "text", "selection")
        self.assertIsInstance(s, rt.Selection)
        got = [x in s for x in ["4000", "4500", "4999", "5000", "3.1.2", "3.2", None]]
        self.assertEqual(got, [True, False, True, False, True, False, False])

    def test_numbers_compare_as_numbers(self):
        s = value({"ranges": [[9, 100]]}, "integer", "selection")
        self.assertTrue(50 in s)
        self.assertFalse(1000 in s)                                    # as text "1000" < "9" would be inside

    def test_nothing_to_include_means_all_but_excluded(self):
        s = value({"exclude": ["X"]}, "text", "selection")
        self.assertTrue("A" in s)
        self.assertFalse("X" in s)


if __name__ == "__main__":
    unittest.main()
