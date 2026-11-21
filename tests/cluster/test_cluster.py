# SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Cluster tests: exactly-once scheduling and failover (CA-018-01) and Erlang
distribution calls to ana_rpc:call/3 (T-003-06, RF-003-06, RNF-003-02).

Run with tests/cluster/run.sh (it starts and stops the second node).
"""

import json
import os
import subprocess
import time
import unittest
import urllib.error
import urllib.request

NODE1 = "http://localhost:" + os.environ.get("ANA_PORT", "8080")   # ports configurable: the host may use them
NODE2 = "http://localhost:" + os.environ.get("ANA2_PORT", "8081")
COOKIE = os.environ.get("ANA_TEST_COOKIE", "ana-cluster-test-cookie")
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
COMPOSE = ["docker", "compose", "-f", os.path.join(ROOT, "docker-compose.yml"),
           "-f", os.path.join(ROOT, "tests", "cluster", "docker-compose.cluster.yml")]


def http(base, method, path, body=None, token=None):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None,
                                 method=method, headers={"Content-Type": "application/json"})
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            t = r.read().decode()
            return r.status, json.loads(t) if t else None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except (urllib.error.URLError, ConnectionError):
        return 0, None


def wait_health(base, timeout=90):
    end = time.time() + timeout
    while time.time() < end:
        if http(base, "GET", "/health")[0] == 200:
            return
        time.sleep(1)
    name = "ana-erp-ana2-1" if base == NODE2 else "ana-erp-ana-1"
    logs = subprocess.run(["docker", "logs", "--tail", "40", name], capture_output=True, text=True).stdout
    raise AssertionError(f"{base} did not become healthy; last lines of {name}:\n{logs}")


def login(base):
    return http(base, "POST", "/api/session", {"username": "admin", "password": os.environ.get("ANA_ADMIN_PASSWORD", "admin")})[1]["token"]


def probe(expr, cookie=COOKIE):
    """Runs an Erlang expression on a throwaway node inside the compose network."""
    network = subprocess.run(["docker", "inspect", "-f", "{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}",
                              "ana-erp-ana-1"], capture_output=True, text=True, check=True).stdout.strip()
    cmd = ["docker", "run", "--rm", "--network", network, "--hostname", "probe.cluster",
           "--network-alias", "probe.cluster", "erlang:27", "erl", "-noshell", "-name", "probe@probe.cluster",
           "-setcookie", cookie, "-eval", expr + ", halt()."]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=120).stdout


class TestCluster(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        wait_health(NODE1)
        wait_health(NODE2)
        cls.token = login(NODE1)

    def test_t_003_06_erlang_distribution_call(self):
        out = probe("io:format(\"~p~n\", [erpc:call('ana@ana1.cluster', ana_rpc, call, "
                    "[<<\"demo.hello\">>, #{<<\"name\">> => <<\"erlang\">>}, <<\"admin\">>])])")
        self.assertIn("{ok,", out, out)
        self.assertIn("erlang", out, out)

    def test_rnf_003_02_wrong_cookie_is_refused(self):
        out = probe("io:format(\"~p~n\", [net_adm:ping('ana@ana1.cluster')])", cookie="wrong-cookie")
        self.assertIn("pang", out, out)

    def test_ca_018_01_exactly_once_and_failover(self):
        name = f"t-cluster-{int(time.time())}"
        s, job = http(NODE1, "POST", "/api/scheduler/jobs",
                      {"name": name, "program": "demo.hello", "triggers": [{"kind": "interval", "interval_s": 1}],
                       "concurrency": "parallel", "max_parallel": 5}, self.token)
        self.assertEqual(s, 200, job)
        try:
            time.sleep(8)
            # Fail over: stop the node that currently leads.
            s, st1 = http(NODE1, "GET", "/api/scheduler/status", token=self.token)
            leader_is_1 = st1["leader"]
            victim = "ana" if leader_is_1 else "ana2"
            survivor = NODE2 if leader_is_1 else NODE1
            subprocess.run(COMPOSE + ["stop", victim], check=True, capture_output=True)
            time.sleep(12)
            token2 = login(survivor)
            s, st2 = http(survivor, "GET", "/api/scheduler/status", token=token2)
            self.assertTrue(st2["leader"], st2)
            s, occ = http(survivor, "GET", f"/api/scheduler/jobs/{job['id']}/occurrences?limit=500", token=token2)
            done = [o for o in occ if o["status"] == "success"]
            times = [o["scheduled_at"] for o in done]
            self.assertEqual(len(times), len(set(times)), "ocorrência executada mais de uma vez")
            self.assertGreaterEqual(len({o["node"] for o in done}), 2, "a liderança não mudou de nó")
            s, execs = http(survivor, "GET", "/api/executions?program=demo.hello&limit=200&mine=1", token=token2)
            self.assertGreaterEqual(len(execs), len(done))
        finally:
            subprocess.run(COMPOSE + ["start", "ana", "ana2"], capture_output=True)
            wait_health(NODE1)
            wait_health(NODE2)                  # the next tests use both nodes
            http(NODE1, "DELETE", f"/api/scheduler/jobs/{job['id']}", token=login(NODE1))

    def test_rf_022_04_orphan_prepared_transactions_recovered(self):
        """A node restart resolves its orphan prepared transactions: decided → committed, others → undone."""
        out = probe('io:format("~s|~s", [erpc:call(\'ana@ana1.cluster\', ana_parallel, gid, '
                    '[<<"0123456789abcdef0123456789abcdef">>, 1]), '
                    'erpc:call(\'ana@ana1.cluster\', ana_parallel, gid, [<<"0123456789abcdef0123456789abcdef">>, 2])])')
        rollback_gid, commit_gid = out.strip().split("|")
        tag = str(int(time.time()))
        pw = os.environ.get("ANA_TEST_EXEC_PASSWORD", "cluster-exec-test-password")

        def psql(sql, url=None):
            cmd = COMPOSE + ["exec", "-T", "db", "psql", "-At", "-v", "ON_ERROR_STOP=1"]
            cmd += [url] if url else ["-U", "ana", "-d", "ana"]
            r = subprocess.run(cmd + ["-c", sql], capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            return r.stdout.strip()
        exec_url = f"postgresql://ana_exec:{pw}@localhost/ana"
        for gid, name in ((rollback_gid, f"orphan-rb-{tag}"), (commit_gid, f"orphan-ok-{tag}")):
            psql(f"BEGIN; INSERT INTO base.party (kind, name) VALUES ('customer', '{name}'); "
                 f"PREPARE TRANSACTION '{gid}';", exec_url)
        psql(f"INSERT INTO ana_system.parallel_decision (main_gid, gids, decision, node) "
             f"VALUES ('{commit_gid}', ARRAY['{commit_gid}'], 'commit', 'ana@ana1.cluster')")
        subprocess.run(COMPOSE + ["restart", "ana"], check=True, capture_output=True)
        wait_health(NODE1)
        self.assertEqual(psql(f"SELECT count(*) FROM pg_prepared_xacts WHERE gid IN ('{rollback_gid}', '{commit_gid}')"), "0")
        self.assertEqual(psql(f"SELECT count(*) FROM base.party WHERE name = 'orphan-rb-{tag}'"), "0")
        self.assertEqual(psql(f"SELECT count(*) FROM base.party WHERE name = 'orphan-ok-{tag}'"), "1")
        self.assertEqual(psql(f"SELECT count(*) FROM ana_system.parallel_decision WHERE main_gid = '{commit_gid}'"), "0")

    def test_ca_065_07_value_changed_on_one_node_is_read_on_the_other(self):
        """Spec 065 (CA-065-07, RNF-065-01): a company value changed through node 1 is read by a routine on node 2
        within 1 s — every node keeps the values in memory and reloads on the database's notice."""
        wait_health(NODE1)
        wait_health(NODE2)
        tag = str(int(time.time() * 1000))[-8:]
        name, prog = f"c{tag}.limite", f"test.cluster_value_{tag}"
        s, c = http(NODE1, "POST", "/api/values", {"name": name, "description": "Teste de cluster", "value_type": "integer"}, self.token)
        self.assertEqual(s, 200, c)
        try:
            s, c = http(NODE1, "POST", f"/api/values/{name}/versions", {"content": 1, "valid_from": "2020-01-01"}, self.token)
            self.assertEqual(s, 200, c)
            s, c = http(NODE1, "PUT", f"/api/programs/{prog}", {"source": "def main(name):\n    return ana.value(name)\n"}, self.token)
            self.assertEqual(s, 200, c)

            last = {}

            def on_node2():
                s, c = http(NODE2, "POST", f"/api/programs/{prog}/run", {"params": {"name": name}}, self.token)
                last["reply"] = (s, c)
                return c.get("result") if s == 200 and isinstance(c, dict) else None
            end = time.time() + 30
            while on_node2() != 1 and time.time() < end:
                time.sleep(0.2)
            self.assertEqual(on_node2(), 1, last.get("reply"))
            s, meta = http(NODE1, "GET", "/api/values/meta", token=self.token)
            s, c = http(NODE1, "POST", f"/api/values/{name}/versions", {"content": 2, "valid_from": meta["today"]}, self.token)
            self.assertEqual(s, 200, c)
            t0 = time.time()
            while on_node2() != 2 and time.time() - t0 < 1.0:
                time.sleep(0.05)
            self.assertEqual(on_node2(), 2, "o outro nó não leu o novo valor em até 1 s")
        finally:
            http(NODE1, "PUT", f"/api/values/{name}", {"archived": True}, self.token)
            http(NODE1, "DELETE", f"/api/programs/{prog}?purge=1", token=self.token)


if __name__ == "__main__":
    unittest.main()
