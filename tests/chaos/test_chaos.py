"""Chaos tests (spec 023, CA-023-01..06, RF-023-06).

Two core nodes behind HAProxy (tests/chaos/run.sh). Each test injects a
failure — misbehaving programs, a node killed, a graceful stop, a rolling
update, a database restart, internal crashes — and checks that the service
keeps answering. Run with tests/chaos/run.sh.
"""

import concurrent.futures
import datetime
import json
import os
import subprocess
import threading
import time
import unittest
import urllib.error
import urllib.request

LB = "http://localhost:8090"
NODE1 = "http://localhost:8080"
NODE2 = "http://localhost:8081"
COOKIE = os.environ.get("ANA_TEST_COOKIE", "ana-cluster-test-cookie")
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
COMPOSE = ["docker", "compose", "-f", os.path.join(ROOT, "docker-compose.yml"),
           "-f", os.path.join(ROOT, "tests", "cluster", "docker-compose.cluster.yml"),
           "-f", os.path.join(ROOT, "tests", "chaos", "docker-compose.chaos.yml")]
SUFFIX = str(int(time.time()))[-6:]


def http(base, method, path, body=None, token=None, timeout=60):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None,
                                 method=method, headers={"Content-Type": "application/json"})
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            t = r.read().decode()
            return r.status, json.loads(t) if t else None
    except urllib.error.HTTPError as e:
        t = e.read().decode()
        try:
            return e.code, json.loads(t) if t else None
        except ValueError:
            return e.code, t
    except (urllib.error.URLError, ConnectionError, TimeoutError, OSError):
        return 0, None


def wait_ready(base, timeout=120):
    end = time.time() + timeout
    while time.time() < end:
        if http(base, "GET", "/health/ready", timeout=5)[0] == 200:
            return
        time.sleep(0.5)
    raise AssertionError(f"{base} não ficou pronto")


def login(base=LB):
    end = time.time() + 60
    while time.time() < end:
        s, c = http(base, "POST", "/api/session", {"username": "admin", "password": os.environ.get("ANA_ADMIN_PASSWORD", "admin")})
        if s == 200:
            return c["token"]
        time.sleep(1)
    raise AssertionError("login falhou")


def compose(*args, check=True):
    return subprocess.run(COMPOSE + list(args), capture_output=True, text=True, check=check, timeout=300)


def probe(expr):
    """Erlang expression on a throwaway node in the compose network (distribution, cookie)."""
    network = subprocess.run(["docker", "inspect", "-f", "{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}",
                              "ana-erp-ana-1"], capture_output=True, text=True, check=True).stdout.strip()
    cmd = ["docker", "run", "--rm", "--network", network, "--hostname", "probe.cluster", "--network-alias",
           "probe.cluster", "erlang:27", "erl", "-noshell", "-name", "probe@probe.cluster", "-setcookie", COOKIE,
           "-eval", expr + ", halt()."]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=180).stdout.strip()


class Load:
    """Background requests; records (time, status, seconds) of each one."""

    def __init__(self, base, token, make, threads=4, pause=0.05):
        self.base, self.token, self.make, self.pause = base, token, make, pause
        self.results, self.stop_flag = [], threading.Event()
        self.threads = [threading.Thread(target=self.loop, daemon=True) for _ in range(threads)]

    def loop(self):
        while not self.stop_flag.is_set():
            method, path, body = self.make()
            t0 = time.time()
            s, _ = http(self.base, method, path, body, self.token, timeout=30)
            self.results.append((t0, s, time.time() - t0))
            time.sleep(self.pause)

    def __enter__(self):
        for t in self.threads:
            t.start()
        return self

    def __exit__(self, *exc):
        self.stop_flag.set()
        for t in self.threads:
            t.join(timeout=40)

    def failures(self, since=0.0, until=None):
        until = until or float("inf")
        return [r for r in self.results if since <= r[0] <= until and r[1] != 200]


class TestChaos(unittest.TestCase):
    PROGRAMS = {
        "exc": ("def main():\n    raise ValueError('falha proposital')\n", {}),
        "mem": ("def main():\n    x = bytearray(512 * 1024 * 1024)\n    return len(x)\n", {"memory_mb": 64}),
        "cpu": ("def main():\n    while True:\n        pass\n", {"cpu_ms": 300, "timeout_ms": 5000}),
        "slowpoke": ("import time\ndef main():\n    time.sleep(10)\n", {"timeout_ms": 500}),
        "kill": ("import os, signal\ndef main():\n    os.kill(os.getpid(), signal.SIGKILL)\n", {}),
        "slow": ("import time\ndef main(s=3):\n    time.sleep(s)\n    return 'done'\n", {"timeout_ms": 60000}),
    }

    @classmethod
    def setUpClass(cls):
        wait_ready(NODE1)
        wait_ready(NODE2)
        wait_ready(LB)
        cls.token = login()
        for key, (src, limits) in cls.PROGRAMS.items():
            s, c = http(LB, "PUT", f"/api/programs/test.chaos_{key}", {"source": src, "limits": limits}, cls.token)
            assert s == 200, c
        # Runs above the default user quota (600/min, 16 at once) for this suite only.
        http(LB, "PUT", "/api/admin/quotas/admin", {"max_concurrent": 0, "runs_per_minute": 0}, cls.token)

    @classmethod
    def tearDownClass(cls):
        token = login()
        http(LB, "PUT", "/api/admin/quotas/admin", {"max_concurrent": None, "runs_per_minute": None}, token)
        for key in cls.PROGRAMS:
            http(LB, "DELETE", f"/api/programs/test.chaos_{key}?purge=1", token=token)

    def run_prog(self, base, key, params=None, token=None):
        return http(base, "POST", f"/api/programs/test.chaos_{key}/run", {"params": params or {}}, token or self.token)

    def core_memory(self):
        out = probe("io:format(\"~b\", [erpc:call('ana@ana1.cluster', fun() -> "
                    "[erlang:garbage_collect(P) || P <- processes()], erlang:memory(total) end)])")
        return int(out)

    # ------------------------------------------------------------------ CA-023-01
    def test_a_misbehaving_programs_never_bring_the_core_down(self):
        for _ in range(30):                       # warm-up before the baseline
            self.run_prog(NODE1, "exc")
        baseline = self.core_memory()
        kinds = ["exc", "mem", "cpu", "slowpoke", "kill"]
        expected = {"exc": "EXCEPTION", "mem": None, "cpu": "CPU_LIMIT", "slowpoke": "TIMEOUT", "kill": "PROCESS_EXITED"}
        codes = {}
        with concurrent.futures.ThreadPoolExecutor(12) as pool:
            for kind, (s, c) in zip([kinds[i % 5] for i in range(1000)],
                                    pool.map(lambda i: self.run_prog(NODE1, kinds[i % 5]), range(1000))):
                self.assertIn(s, (422,), (kind, s, c))
                codes.setdefault(kind, set()).add(c["error"]["code"])
        for kind, code in expected.items():
            if code:
                self.assertEqual(codes[kind], {code}, kind)
        self.assertTrue(codes["mem"] <= {"MEMORY", "PROCESS_EXITED"}, codes["mem"])
        self.assertEqual(http(NODE1, "GET", "/health/ready")[0], 200)
        time.sleep(3)
        after = self.core_memory()
        self.assertLess(after, baseline * 1.5 + 30 * 1024 * 1024, f"memória do núcleo: {baseline} → {after}")

    # ------------------------------------------------------------------ CA-023-06
    def test_b_internal_crashes_are_isolated_and_restarted(self):
        out = probe("Old = erpc:call('ana@ana1.cluster', erlang, whereis, [ana_scheduler]), "
                    "erpc:call('ana@ana1.cluster', erlang, exit, [Old, kill]), timer:sleep(1500), "
                    "New = erpc:call('ana@ana1.cluster', erlang, whereis, [ana_scheduler]), "
                    "io:format(\"~p\", [is_pid(New) andalso New =/= Old])")
        self.assertEqual(out, "true", "o supervisor deveria reiniciar o agendador")
        # An execution process killed in the middle: the caller gets an error, never hangs.
        result = {}
        t = threading.Thread(target=lambda: result.update(r=self.run_prog(NODE1, "slow", {"s": 20})))
        t.start()
        time.sleep(2)
        out = probe("{_, Pid, _, _, _, _} = lists:keyfind(<<\"test.chaos_slow\">>, 4, "
                    "erpc:call('ana@ana1.cluster', ets, tab2list, [ana_executions])), "
                    "erpc:call('ana@ana1.cluster', erlang, exit, [Pid, kill]), io:format(\"killed\")")
        self.assertEqual(out, "killed")
        t.join(timeout=15)
        self.assertFalse(t.is_alive(), "o chamador ficou sem resposta")
        s, c = result["r"]
        self.assertEqual((s, c["error"]["code"]), (422, "INTERNAL"), c)
        self.assertEqual(http(NODE1, "GET", "/health/ready")[0], 200)

    # ------------------------------------------------------------------ CA-023-04
    def test_c_graceful_stop_lets_running_executions_finish(self):
        token2 = login(NODE2)
        result, readiness = {}, []
        t = threading.Thread(target=lambda: result.update(r=self.run_prog(NODE2, "slow", {"s": 9}, token2)))
        t.start()
        time.sleep(1)
        stopper = threading.Thread(target=lambda: compose("stop", "ana2"))
        stopper.start()
        time.sleep(1)
        readiness.append(http(NODE2, "GET", "/health/ready", timeout=3)[0])   # out of the balancer at once
        accepted = self.run_prog(NODE2, "exc", token=token2)                    # still served while it notices
        time.sleep(4)                                                           # drain delay (4 s) is over
        refused = self.run_prog(NODE2, "exc", token=token2)
        t.join(timeout=30)
        stopper.join(timeout=60)
        try:
            self.assertEqual(result["r"][0], 200, result)
            self.assertEqual(result["r"][1]["result"], "done")
            self.assertEqual(readiness, [503], "durante a drenagem o nó sai da prontidão")
            self.assertEqual(accepted[1]["error"]["code"], "EXCEPTION", accepted)
            self.assertEqual((refused[0], refused[1]["error"]["code"]), (503, "DRAINING"), refused)
        finally:
            compose("start", "ana2")
            wait_ready(NODE2)

    # ------------------------------------------------------------------ CA-023-03
    def test_d_killing_a_node_behind_the_balancer(self):
        token2 = login(NODE2)
        orphan = threading.Thread(target=lambda: self.run_prog(NODE2, "slow", {"s": 30}, token2), daemon=True)
        orphan.start()                           # running on ana2 when it is killed (RF-023-04)
        with Load(LB, self.token, lambda: ("GET", "/api/programs", None)) as load:
            time.sleep(3)
            killed_at = time.time()
            compose("kill", "ana2")
            time.sleep(12)
        try:
            window = 4                           # detection: 2 checks × 1 s, plus margin
            late = load.failures(since=killed_at + window)
            self.assertEqual(late, [], f"falhas depois da janela de detecção: {late[:5]}")
            self.assertGreater(len(load.results), 50)
            s, st = http(NODE1, "GET", "/api/scheduler/status", token=login(NODE1))
            self.assertTrue(st["leader"], "o nó sobrevivente deveria liderar o agendador")
        finally:
            compose("start", "ana2")
            wait_ready(NODE2)
            wait_ready(LB)
        s, rows = http(NODE1, "GET", "/api/admin/audit/executions?program=test.chaos_slow&limit=1", token=self.token)
        self.assertEqual((rows[0]["status"], rows[0]["error"]), ("error", "INTERRUPTED"), rows[:1])

    # ------------------------------------------------------------------ CA-023-05
    def test_e_rolling_update_without_errors(self):
        calls = [("GET", "/api/programs", None),
                 ("POST", "/api/programs/demo.hello/run", {"params": {"name": "rolling"}})]
        i = {"n": 0}

        def make():
            i["n"] += 1
            return calls[i["n"] % 2]
        with Load(LB, self.token, make, threads=3) as load:
            time.sleep(2)
            for service, base in (("ana2", NODE2), ("ana", NODE1)):
                compose("stop", service)
                compose("start", service)
                wait_ready(base)
                time.sleep(3)                    # the balancer sees it ready again
        failures = load.failures()
        self.assertEqual(failures, [], f"{len(failures)} falha(s) na atualização: {failures[:5]}")
        self.assertGreater(len(load.results), 50)

    # ------------------------------------------------------------------ CA-023-02
    def test_f_database_restart_fails_fast_and_recovers(self):
        started = {s: compose("ps", "-q", s).stdout.strip() for s in ("ana", "ana2")}
        before = {s: subprocess.run(["docker", "inspect", "-f", "{{.State.StartedAt}}", cid], capture_output=True,
                                    text=True).stdout.strip() for s, cid in started.items()}
        with Load(LB, self.token, lambda: ("POST", "/api/programs/demo.hello/run", {"params": {"name": "db"}})) as load:
            time.sleep(2)
            down_at = time.time()
            compose("restart", "db")
            up_at = time.time()
            end = time.time() + 40
            while time.time() < end:
                if load.results and load.results[-1][1] == 200 and load.results[-1][0] > up_at:
                    break
                time.sleep(0.5)
            recovered_at = time.time()
            time.sleep(3)
        slow = [r for r in load.results if down_at <= r[0] <= up_at and r[2] > 6]
        self.assertEqual(slow, [], f"durante a queda as requisições devem falhar rápido: {slow[:3]}")
        self.assertLess(recovered_at - up_at, 30, "o núcleo deveria voltar sozinho em segundos")
        self.assertEqual(load.failures(since=recovered_at + 1), [], "depois da volta tudo deve funcionar")
        after = {s: subprocess.run(["docker", "inspect", "-f", "{{.State.StartedAt}}", cid], capture_output=True,
                                   text=True).stdout.strip() for s, cid in started.items()}
        self.assertEqual(before, after, "o núcleo não pode ter sido reiniciado")
        self.assertEqual(http(NODE1, "GET", "/health/ready")[0], 200)

    # ------------------------------------------------------------------ RF-023-06
    def test_z_point_in_time_restore(self):
        def psql(sql):
            r = subprocess.run(["docker", "compose", "-f", os.path.join(ROOT, "docker-compose.yml"), "exec", "-T", "db",
                                "psql", "-U", "postgres", "-d", "ana", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql],
                               capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            return r.stdout.strip()
        script = os.path.join(ROOT, "scripts")
        subprocess.run([os.path.join(script, "backup.sh"), "enable"], check=True, capture_output=True, timeout=180)
        try:
            wait_ready(NODE1)
            subprocess.run([os.path.join(script, "backup.sh"), "base"], check=True, capture_output=True, timeout=300)
            psql(f"INSERT INTO base.party (kind, name) VALUES ('customer', 'pitr-a-{SUFFIX}')")
            time.sleep(1.5)
            target = psql("SELECT now()::text")
            time.sleep(1.5)
            psql(f"INSERT INTO base.party (kind, name) VALUES ('customer', 'pitr-b-{SUFFIX}')")
            psql("SELECT pg_switch_wal()")
            time.sleep(5)                            # archive_command copies the segment
            r = subprocess.run([os.path.join(script, "restore-test.sh"), target,
                                f"SELECT string_agg(name, ',' ORDER BY name) FROM base.party WHERE name LIKE 'pitr-%-{SUFFIX}'"],
                               capture_output=True, text=True, timeout=300)
            self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
            self.assertEqual(r.stdout.strip().splitlines()[-1], f"pitr-a-{SUFFIX}",
                             "restaurado até o instante: A existe, B (posterior) não")
        finally:
            psql("ALTER SYSTEM RESET archive_mode")
            psql("ALTER SYSTEM RESET archive_command")
            psql("ALTER SYSTEM RESET archive_timeout")
            subprocess.run(["docker", "compose", "-f", os.path.join(ROOT, "docker-compose.yml"), "restart", "db"],
                           capture_output=True, timeout=180)
            wait_ready(NODE1)


if __name__ == "__main__":
    unittest.main()
