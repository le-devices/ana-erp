# SPDX-FileCopyrightText: 2026 LE Devices
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Installation (spec 036): CA-036-01..03 against the stack installed by tests/install/run.sh."""
import json
import os
import ssl
import subprocess
import threading
import time
import unittest
import urllib.error
import urllib.request

DIR = os.environ["ANA_INSTALL_DIR"]
BASE = "https://127.0.0.1:18443"
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE            # internal certificate of the test


def env():
    out = {}
    with open(os.path.join(DIR, ".env")) as f:
        for line in f:
            if "=" in line and not line.startswith("#"):
                k, v = line.rstrip("\n").split("=", 1)
                out[k] = v.strip('"')
    return out


def http(method, path, body=None, token=None, timeout=30):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode() if body is not None else None, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            t = r.read().decode()
            return r.status, json.loads(t) if t else None
    except urllib.error.HTTPError as e:
        t = e.read().decode()
        try:
            return e.code, json.loads(t)
        except ValueError:
            return e.code, t


def ctl(*args):
    return subprocess.run([os.path.join(DIR, "ana-ctl"), "--dir", DIR, *args], capture_output=True, text=True, timeout=900)


class TestInstall(unittest.TestCase):
    NEW_PASSWORD = "Instalado-2026-ok!"

    @classmethod
    def setUpClass(cls):
        s, c = http("POST", "/api/session", {"username": "admin", "password": env()["ANA_ADMIN_PASSWORD"]})
        assert s == 200, (s, c)
        cls.first_token = c["token"]

    def token(self):
        s, c = http("POST", "/api/session", {"username": "admin", "password": self.NEW_PASSWORD})
        self.assertEqual(s, 200, c)
        return c["token"]

    def test_a_ca_036_01_secure_by_default(self):
        e = env()
        self.assertEqual(oct(os.stat(os.path.join(DIR, ".env")).st_mode & 0o777), "0o600")
        for k in ("POSTGRES_PASSWORD", "ANA_DB_PASSWORD", "ANA_MASTER_KEY", "ANA_COOKIE", "ANA_ADMIN_PASSWORD"):
            self.assertGreaterEqual(len(e[k]), 20, k)
        self.assertNotIn("change", e["ANA_DB_PASSWORD"])
        s, me = http("GET", "/api/me", token=self.first_token)
        self.assertTrue(me["must_change_password"])                          # initial password must be changed
        self.assertEqual(me["instance"]["role"], "production")
        s, c = http("GET", "/api/programs", token=self.first_token)
        self.assertEqual(s, 403)                                             # nothing before the change
        s, c = http("POST", "/api/me/password", {"current": e["ANA_ADMIN_PASSWORD"], "new": self.NEW_PASSWORD}, self.first_token)
        self.assertEqual(s, 200, c)
        t = self.token()
        s, c = http("POST", "/api/admin/checks/run", {"category": "security"}, t)
        self.assertEqual(s, 200, c)
        s, c = http("GET", "/api/admin/checks?category=security&status=open", token=t)
        bad = [f["rule"] + ":" + f["target"] for f in c["findings"] if f["severity"] == "critical"]
        self.assertEqual(bad, [])                                            # no example secret, no trivial password
        s, c = http("POST", "/api/sql", {"sql": "SELECT count(*) FROM base.party"}, t)
        self.assertEqual(c["rows"][0][0], 0)                                 # no demonstration data
        s, h = http("GET", "/health")
        self.assertEqual(h["status"], "ok")

    def test_b_doctor_and_backups(self):
        r = ctl("doctor")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("última cópia do banco", r.stdout)
        r = ctl("restore-test")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_b2_rf_063_05_archive_window_is_an_installation_parameter(self):
        """RF-063-05/D10: the WAL archive window (RPO) comes from --archive-minutes and changes with ana-ctl."""
        def show():
            r = subprocess.run(["docker", "compose", "--project-directory", DIR, "-f", os.path.join(DIR, "docker-compose.prod.yml"),
                                "--env-file", os.path.join(DIR, ".env"), "exec", "-T", "db", "psql", "-U", "postgres", "-At",
                                "-c", "SHOW archive_timeout"], capture_output=True, text=True, timeout=60)
            return r.stdout.strip()
        self.assertEqual(env()["ANA_PG_ARCHIVE_TIMEOUT"], "600")             # run.sh installs with --archive-minutes 10
        self.assertEqual(show(), "10min")
        self.assertEqual(ctl("archive-minutes", "0").returncode, 2)          # never disables the archive window
        self.assertEqual(ctl("archive-minutes", "61").returncode, 2)
        r = ctl("archive-minutes", "15")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((env()["ANA_PG_ARCHIVE_TIMEOUT"], show()), ("900", "15min"))
        self.assertEqual(oct(os.stat(os.path.join(DIR, ".env")).st_mode & 0o777), "0o600")
        self.assertIn("15 min", ctl("archive-minutes").stdout)
        s, h = http("GET", "/health")
        self.assertEqual(h["status"], "ok")                                  # the ERP is back after the database restart

    def test_c_ca_036_02_upgrade_without_errors(self):
        t = self.token()
        old = env()["ANA_IMAGE"]
        new = old + "-next"
        subprocess.run(["docker", "tag", old, new], check=True)
        results, stop = [], threading.Event()

        def load():
            while not stop.is_set():
                try:
                    s, _ = http("GET", "/api/programs", token=t, timeout=20)
                except Exception as e:                                      # connection errors count as failures
                    s = repr(e)
                results.append(s)
                time.sleep(0.05)
        threads = [threading.Thread(target=load) for _ in range(3)]
        for th in threads:
            th.start()
        try:
            r = ctl("upgrade", "--image", new)
        finally:
            stop.set()
            for th in threads:
                th.join()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        failures = [x for x in results if x != 200]
        self.assertEqual(failures, [], f"{len(failures)} falha(s) de {len(results)} durante a atualização")
        self.assertGreater(len(results), 50)
        self.assertEqual((env()["ANA_IMAGE"], env()["ANA_IMAGE_PREVIOUS"]), (new, old))

    def test_d_ca_036_03_uninstall_keeps_data(self):
        project = env()["ANA_PROJECT"]
        r = ctl("uninstall")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        vols = subprocess.run(["docker", "volume", "ls", "-q", "--filter", f"name={project}_"], capture_output=True, text=True).stdout
        self.assertIn(f"{project}_data", vols)
        r = ctl("up")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        end = time.time() + 120
        while time.time() < end:
            try:
                if http("GET", "/health")[0] == 200:
                    break
            except Exception:
                pass
            time.sleep(2)
        self.token()                                                         # the changed password survived


if __name__ == "__main__":
    unittest.main()
