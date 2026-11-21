# SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Real primary failover with a local PostgreSQL cluster (spec 023, T-023-09).

db = primary, db2 = streaming replica; two core nodes with ANA_DB_HOST=db,db2 and
ANA_DB_READ_HOSTS=db2 behind HAProxy. Run with tests/pg_ha/run.sh.
"""

import json
import os
import subprocess
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "chaos"))
from test_chaos import LB, NODE1, NODE2, Load, http, login, wait_ready  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
COMPOSE = ["docker", "compose"] + sum([["-f", os.path.join(ROOT, f)] for f in (
    "docker-compose.yml", "tests/cluster/docker-compose.cluster.yml", "tests/chaos/docker-compose.chaos.yml",
    "tests/pg_ha/docker-compose.pg-ha.yml")], [])
SUFFIX = str(int(time.time()))[-6:]


def compose(*args, check=True):
    return subprocess.run(COMPOSE + list(args), capture_output=True, text=True, check=check, timeout=300)


def psql(service, sql):
    r = compose("exec", "-T", service, "psql", "-U", "postgres", "-d", "ana", "-At", "-c", sql, check=False)
    return r.stdout.strip() if r.returncode == 0 else None


def psql_diag(service, sql):
    """Like psql, but keeps the error text (diagnosis only)."""
    r = compose("exec", "-T", service, "psql", "-U", "postgres", "-d", "ana", "-At", "-c", sql, check=False)
    return r.stdout.strip() if r.returncode == 0 else "erro: " + (r.stderr.strip()[-300:] or str(r.returncode))


def wait_healthy(service, timeout=120):
    end = time.time() + timeout
    while time.time() < end:
        if psql(service, "SELECT 1") == "1":
            return
        time.sleep(1)
    raise AssertionError(f"{service} não respondeu")


class TestPrimaryFailover(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        wait_healthy("db2")
        end = time.time() + 60
        while psql("db2", "SELECT pg_is_in_recovery()") != "t" and time.time() < end:
            time.sleep(1)
        for base in (NODE1, NODE2, LB):
            wait_ready(base)
        cls.token = login()
        # The load runs above the default per-user quota (600/min): lifted for this suite only, as in the chaos suite.
        http(LB, "PUT", "/api/admin/quotas/admin", {"max_concurrent": 0, "runs_per_minute": 0}, cls.token)

    @classmethod
    def tearDownClass(cls):
        for base in (LB, NODE1, NODE2):
            try:
                s, _ = http(base, "PUT", "/api/admin/quotas/admin", {"max_concurrent": None, "runs_per_minute": None}, login(base))
                if s == 200:
                    break
            except Exception:                    # a node may still be restarting after case (c)
                continue

    def marker_program(self, base, token, tag):
        name = "test.pg_ha_marker"
        http(base, "PUT", f"/api/programs/{name}", {"source": "def main(tag):\n    return ana.sql_value(\"INSERT INTO base.party "
                                                            "(kind, name) VALUES ('customer', $1) RETURNING id\", tag)\n"}, token)
        return http(base, "POST", f"/api/programs/{name}/run", {"params": {"tag": tag}}, token)

    def test_a_console_reads_on_the_replica_and_falls_back(self):
        s, c = http(NODE1, "POST", "/api/sql", {"sql": "SELECT pg_is_in_recovery() AS replica"}, self.token)
        self.assertEqual(s, 200, c)
        self.assertEqual(c["rows"][0][0], True, "o console deveria ler na réplica")
        compose("stop", "db2")
        try:
            s, c = http(NODE1, "POST", "/api/sql", {"sql": "SELECT pg_is_in_recovery() AS replica"}, self.token)
            self.assertEqual(s, 200, c)
            self.assertEqual(c["rows"][0][0], False, "sem réplica, o primário responde")
        finally:
            compose("start", "db2")
            wait_healthy("db2")

    def test_b_promoted_replica_takes_over_under_load(self):
        started = {s: compose("ps", "-q", s).stdout.strip() for s in ("ana", "ana2")}
        before = {s: subprocess.run(["docker", "inspect", "-f", "{{.State.StartedAt}}", c], capture_output=True,
                                    text=True).stdout.strip() for s, c in started.items()}
        # RF-023-08: the session is streamed to the replica like any other data (never UNLOGGED), so the promoted
        # replica keeps everyone signed in.
        token_sql = self.token.replace("'", "''")
        before_promote = {
            "replication": psql_diag("db", "SELECT string_agg(state || ' ' || COALESCE(replay_lag::text, '0'), ', ') FROM pg_stat_replication"),
            "session_on_replica": psql_diag("db2", f"SELECT count(*) FROM ana_system.session WHERE token_hash = sha256(convert_to('{token_sql}', 'UTF8'))"),
        }
        self.assertEqual(before_promote["session_on_replica"], "1", f"a sessão precisa estar na réplica antes da troca: {before_promote}")
        with Load(LB, self.token, lambda: ("POST", "/api/programs/demo.hello/run", {"params": {"name": "failover"}})) as load:
            time.sleep(2)
            self.assertEqual(psql("db2", "SELECT pg_promote()"), "t")
            compose("stop", "db")
            switched = time.time()
            time.sleep(15)
        # While the replica takes over, the session stays valid: "try again" (503), never a sign-out (401).
        signed_out = [r for r in load.results if r[1] == 401]
        if signed_out:
            before_promote["session_on_new_primary"] = psql_diag(
                "db2", f"SELECT count(*) || ' ' || COALESCE(max(expires_at)::text, '-') FROM ana_system.session "
                       f"WHERE token_hash = sha256(convert_to('{token_sql}', 'UTF8'))")
            before_promote["db2_in_recovery"] = psql_diag("db2", "SELECT pg_is_in_recovery()")
        self.assertEqual(signed_out, [], "a troca de primário não pode invalidar a sessão: "
                         f"{[(round(r[0] - switched, 1), r[1], r[3]) for r in signed_out[:5]]} (s após a troca, status, código); "
                         f"antes da promoção: {before_promote}")
        late = load.failures(since=switched + 10)
        self.assertEqual(late, [], f"depois de 10 s o núcleo deveria estar no novo primário: {late[:5]}")
        self.assertGreater(len(load.results), 30)
        after = {s: subprocess.run(["docker", "inspect", "-f", "{{.State.StartedAt}}", c], capture_output=True,
                                   text=True).stdout.strip() for s, c in started.items()}
        self.assertEqual(before, after, "o núcleo não pode ter sido reiniciado")
        tag = f"pgha-b-{SUFFIX}"
        s, c = self.marker_program(LB, self.token, tag)
        self.assertEqual(s, 200, c)
        self.assertEqual(psql("db2", f"SELECT count(*) FROM base.party WHERE name = '{tag}'"), "1")

    def test_c_old_primary_coming_back_is_not_used(self):
        # db comes back still believing it is the primary (no demotion): split brain.
        compose("start", "db")
        wait_healthy("db")
        self.assertEqual(psql("db", "SELECT pg_is_in_recovery()"), "f")
        # A fresh node (no memory of the last primary) must pick the newer timeline (db2).
        compose("restart", "ana")
        wait_ready(NODE1)
        token = login(NODE1)
        tag = f"pgha-c-{SUFFIX}"
        s, c = self.marker_program(NODE1, token, tag)
        self.assertEqual(s, 200, c)
        self.assertEqual(psql("db2", f"SELECT count(*) FROM base.party WHERE name = '{tag}'"), "1")
        self.assertEqual(psql("db", f"SELECT count(*) FROM base.party WHERE name = '{tag}'"), "0",
                         "o primário antigo não pode receber gravações")


if __name__ == "__main__":
    unittest.main()
