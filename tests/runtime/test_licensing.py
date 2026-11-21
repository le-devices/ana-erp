# SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The licensing checks of the repository (spec 066, T-066-02, T-066-05): SPDX lines, dependency licenses and the
credentials scan of what a pull request adds."""
import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import licensing_check as L  # noqa: E402


class Headers(unittest.TestCase):
    def test_t_066_02_every_source_file_of_the_repository_has_the_spdx_lines(self):
        self.assertTrue(L.headers())

    def test_t_066_02_product_programs_and_migrations_are_licensed_by_reuse_toml(self):
        self.assertFalse(L.needs_header("priv/programs/sales.create_order.py"))
        self.assertFalse(L.needs_header("priv/migrations/070_undo_and_confirm.sql"))
        self.assertTrue(L.needs_header("src/ana_undo.erl"))
        self.assertTrue(L.needs_header("priv/www/palette.js"))
        self.assertTrue(L.needs_header("deploy/initdb.sql"))
        self.assertEqual(L.style_of("priv/www/studio.css"), ("/* ", " */"))
        self.assertEqual(L.style_of("src/ana.app.src"), ("%% ", ""))
        reuse = open(os.path.join(ROOT, "REUSE.toml"), encoding="utf-8").read()
        for path in L.BY_REUSE:
            self.assertIn(path.replace("/*", "/**"), reuse)


class Dependencies(unittest.TestCase):
    def test_t_066_05_every_locked_dependency_has_an_accepted_license(self):
        self.assertTrue(L.deps())
        notice = open(os.path.join(ROOT, "NOTICE"), encoding="utf-8").read()
        for name, lic in L.DEPENDENCIES.items():
            self.assertIn(lic, L.ACCEPTED)
            self.assertIn(name, notice)


class Credentials(unittest.TestCase):
    def scan(self, path, text):
        """Commits `text` in `path` of a scratch repository on top of a base, and scans what was added."""
        with tempfile.TemporaryDirectory() as d:
            run = lambda *a: subprocess.run(["git", *a], cwd=d, check=True, capture_output=True)  # noqa: E731
            run("init", "-q", "-b", "base")
            run("-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "base")
            run("checkout", "-q", "-b", "work")
            os.makedirs(os.path.dirname(os.path.join(d, path)) or d, exist_ok=True)
            with open(os.path.join(d, path), "w") as f:
                f.write(text)
            run("add", "-A")
            run("-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "work")
            old, L.ROOT = L.ROOT, d
            try:
                # The checker prints its findings as GitHub annotations: the deliberate fakes of this test must not
                # show up as errors in the summary of the run.
                with contextlib.redirect_stdout(io.StringIO()):
                    return L.secrets("base")
            finally:
                L.ROOT = old

    def test_rnf_066_02_credentials_added_are_refused(self):
        token = "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"
        self.assertFalse(self.scan("app/config.py", f"TOKEN = '{token}'\n"))
        self.assertFalse(self.scan("deploy/key.pem", "-----BEGIN " + "PRIVATE KEY-----\nMC4CAQ\n"))
        self.assertFalse(self.scan("x.js", "const k = 'AKIA" + "ABCDEFGHIJKLMNOP';\n"))

    def test_rnf_066_02_known_test_values_and_plain_code_pass(self):
        self.assertTrue(self.scan("tests/integration/license_test.key", "-----BEGIN " + "PRIVATE KEY-----\nMC4\n"))
        self.assertTrue(self.scan("t.py", "secret = 'sk_live_abcdefgh12345678'\n"))
        self.assertTrue(self.scan("app.py", "password = os.environ['ANA_DB_PASSWORD']\n"))


if __name__ == "__main__":
    unittest.main()
