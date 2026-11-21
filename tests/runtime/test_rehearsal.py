# SPDX-FileCopyrightText: 2026 LE Devices
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Universal rehearsal (spec 056) without a database: what the inspection says a program writes and uses, so the
catalog offers "Ensaiar" exactly on the routines that write (RF-056-03, CA-056-02).

Run: python3 -m unittest tests/runtime/test_rehearsal.py
"""

import ast
import glob
import importlib.util
import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_spec = importlib.util.spec_from_file_location("ana_runtime_r", os.path.join(ROOT, "priv", "python", "ana_runtime.py"))
rt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rt)


def effects(source):
    return rt.program_effects(ast.parse(source))


def catalog():
    """The same closure as ana_system.writing_programs(), over the product's programs (database functions apart)."""
    progs = {}
    for path in glob.glob(os.path.join(ROOT, "priv", "programs", "*.py")):
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        kind = "library" if "# ana:kind library" in src else "program"
        progs[os.path.basename(path)[:-3]] = (kind,) + effects(src)
    w = {n for n, (k, wr, _) in progs.items() if k == "program" and wr}
    w |= {f"{n}:{f}" for n, (k, wr, _) in progs.items() if k == "library" for f in wr}
    changed = True
    while changed:
        changed = False
        for n, (k, _, edges) in progs.items():
            for e in edges:
                src, dst = e.split(">", 1)
                ref = n if k == "program" else f"{n}:{src}"
                if dst in w and ref not in w:
                    w.add(ref)
                    changed = True
    return progs, w


class Inspection(unittest.TestCase):
    """RF-056-03: writes and uses, per function."""

    def test_writes_by_sql_email_files_schedule_and_http(self):
        self.assertEqual(effects("def main():\n    ana.sql_one('UPDATE sales.sales_order SET status = $1 WHERE id = $2', 'X', 1)\n")[0], ["main"])
        self.assertEqual(effects("def main():\n    ana.send_email('a@b.c', 'oi', text='x')\n")[0], ["main"])
        self.assertEqual(effects("def main():\n    ana.files.put('a.txt', 'x')\n")[0], ["main"])
        self.assertEqual(effects("def main():\n    ana.schedule_job('x.y', 'x.z', cron='0 1 * * *')\n")[0], ["main"])
        self.assertEqual(effects("def main():\n    ana.http('bank', 'POST', '/pay')\n")[0], ["main"])

    def test_reading_is_not_writing(self):
        self.assertEqual(effects("def main():\n    ana.sql('SELECT id FROM sales.sales_order WHERE id = $1', 1)\n"
                                 "    ana.http('cnpj', 'GET', '/x')\n    ana.files.get(3)\n    ana.files.list()\n")[0], [])

    def test_local_calls_and_edges(self):
        writing, uses = effects("from ana_lib.master import core\n"
                                "from ana_lib.docs.common import link as doc_link\n"
                                "def save(x):\n    ana.sql_exec('INSERT INTO s.t (a) VALUES ($1)', x)\n"
                                "def main(x):\n    save(x)\n    core.get('item', 1)\n    doc_link('order', 1)\n"
                                "    ana.call('sales.create_order', customer=1)\n"
                                "    ana.sql('SELECT flow.skip($1)', x)\n")
        self.assertEqual(writing, ["main", "save"])                      # main writes through save
        for e in ("main>master.core:get", "main>docs.common:link", "main>sales.create_order", "main>db:flow.skip"):
            self.assertIn(e, uses)


class ProductCatalog(unittest.TestCase):
    """CA-056-02: the routines of the product that write are the ones offered to rehearse — and only those."""

    def test_ca_056_02_writers_and_readers(self):
        progs, w = catalog()
        for n in ("sales.invoice_order", "sales.create_order", "projects.invoice_project", "master.import", "supply.receive",
                  "tax.save_rule", "bpm.discover"):
            if n in progs:
                self.assertIn(n, w, f"{n} grava e não seria oferecido para ensaio")
        for n in ("docs.view", "inventory.balance", "finance.trial_balance", "master.search", "tax.overview"):
            if n in progs:
                self.assertNotIn(n, w, f"{n} só lê e seria oferecido para ensaio")

    def test_every_program_with_write_sql_is_a_writer(self):
        progs, w = catalog()
        missing = sorted(n for n, (k, wr, _) in progs.items() if k == "program" and wr and n not in w)
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
