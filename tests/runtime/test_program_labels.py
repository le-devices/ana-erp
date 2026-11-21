# SPDX-FileCopyrightText: 2026 LE Devices
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Every field of every product program has a Portuguese label (spec 029: no raw English names
on screen), and columns of rows editors too."""

import ast
import glob
import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class TestProgramLabels(unittest.TestCase):
    def test_every_param_and_column_has_a_label(self):
        missing = []
        for f in sorted(glob.glob(os.path.join(ROOT, "priv", "programs", "*.py"))):
            tree = ast.parse(open(f, encoding="utf-8").read())
            for node in tree.body:
                if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "PARAMS" for t in node.targets):
                    for name, spec in ast.literal_eval(node.value).items():
                        if not spec.get("label"):
                            missing.append(f"{os.path.basename(f)}: {name}")
                        for col, cs in (spec.get("columns") or {}).items():
                            if not cs.get("label"):
                                missing.append(f"{os.path.basename(f)}: {name}.{col}")
        self.assertEqual(missing, [], "campos sem rótulo: " + ", ".join(missing))


if __name__ == "__main__":
    unittest.main()
