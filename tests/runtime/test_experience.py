# SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Spec 050 phase 3 (D3, RF-050-02): rules of the premium experience that can be checked on the programs
themselves, without a screen. The Studio crawler (tests/studio/crawl.mjs) checks the screens."""

import glob
import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def routines():
    """Programs a person opens as a routine: not libraries and not home-panel indicators."""
    out = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "priv", "programs", "*.py"))):
        src = open(path, encoding="utf-8").read()
        if re.search(r"^# ana:kind library", src, re.M) or re.search(r"^# ana:indicator", src, re.M):
            continue
        out[os.path.basename(path)[:-3]] = src
    return out


class TestRoutineForms(unittest.TestCase):
    def test_rf_050_02_every_routine_declares_its_params(self):
        """A routine without PARAMS opens a raw JSON box: unusable for an operation user (P18)."""
        missing = sorted(n for n, src in routines().items() if not re.search(r"^PARAMS\s*=", src, re.M))
        self.assertEqual(missing, [], "rotinas sem PARAMS (o Estúdio mostraria uma caixa de JSON)")

    # Opens the situation without parameters (no change); closing is undone by reopening, with a reason.
    CONFIRM_EXEMPT = {"finance.close_period"}

    def test_rf_050_05_irreversible_routines_confirm_or_offer_undo(self):
        """D5: what cancels, deletes, closes or writes off says the consequence before running, unless it offers undo."""
        risky = re.compile(r"(^|[._])(cancel|delete|discard|close|remove|purge|write_off|void)")
        missing = sorted(n for n, src in routines().items()
                         if risky.search(n.split(".", 1)[1]) and n not in self.CONFIRM_EXEMPT
                         and not re.search(r"^# ana:confirm \S", src, re.M) and "offer_undo" not in src)
        self.assertEqual(missing, [], "ações irreversíveis sem confirmação com consequência nem desfazer")

    def test_d3_routines_that_write_show_the_next_step(self):
        """D3 (RF-020-10): a routine that writes ends with its next step (NEXT, ana.actions or row actions).
        The ones still without it are listed in next_step_pending.txt (T-050-17): the list only shrinks."""
        import sys
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from test_rehearsal import catalog
        _, writers = catalog()
        menu = routines()
        lacking = {n for n in writers if n in menu and not re.search(r"^# ana:menu no", menu[n], re.M)
                   and not (re.search(r"^NEXT\s*=", menu[n], re.M) or "ana.actions(" in menu[n] or "_actions" in menu[n])}
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "next_step_pending.txt")
        pending = {l.strip() for l in open(path, encoding="utf-8") if l.strip() and not l.startswith("#")}
        self.assertEqual(sorted(lacking - pending), [], "rotina nova que grava sem próximo passo (declare NEXT)")
        self.assertEqual(sorted(pending - lacking), [], "já tem próximo passo: tire da lista next_step_pending.txt")


if __name__ == "__main__":
    unittest.main()
