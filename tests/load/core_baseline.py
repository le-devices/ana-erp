"""Core baseline (spec 062, T-062-01; constitution P20): the numbers every Erlang-side change is compared with.

Measures, on the running stack:
  outbox    time from a message written in the outbox (ana.send in a committed execution) to delivered
            (integration worker → delivery program), p50/p95 over N messages
  execution round trip of a trivial program through /api/programs/<name>/run, sequential, p50/p95
  load      the sizing mix (tests/load/sizing_load.py) at a fixed number of users: actions/s and worst p95
  idle      BEAM memory and process count after the load (from /metrics)
Everything it creates is named test.* / t…_baseline and removed at the end.

    python3 tests/load/core_baseline.py --label antes [--users 60] [--json tests/load/results/<data>-core-<label>.json]
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sizing_load as S  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def psql(sql):
    r = subprocess.run(["docker", "compose", "exec", "-T", "db", "psql", "-U", "ana", "-d", "ana", "-At", "-c", sql],
                       cwd=REPO, capture_output=True, text=True, timeout=60)
    return r.stdout.strip()


def pct(v, p):
    v = sorted(v)
    return round(v[min(len(v) - 1, int(len(v) * p))], 1) if v else None


def metrics(token):
    import urllib.request
    req = urllib.request.Request(S.URL + "/metrics", headers={"Authorization": "Bearer " + token})
    out = {}
    with urllib.request.urlopen(req, timeout=30) as r:
        for line in r.read().decode().splitlines():
            if line.startswith('ana_beam_memory_bytes{kind="total"}'):
                out["beam_memory_mb"] = round(int(line.split()[-1]) / 1048576, 1)
            elif line.startswith("ana_beam_processes "):
                out["beam_processes"] = int(line.split()[-1])
    return out


def outbox_latency(token, tag, n):
    out_prog, sender, conn = f"test.base_out_{tag}", f"test.base_send_{tag}", f"t{tag}_baseline"
    S.http("PUT", f"/api/programs/{out_prog}", {"source": "def main(message, connector, attempt=1):\n    return 'ok'\n"}, token)
    S.http("PUT", f"/api/admin/connectors/{conn}", {"kind": "http_api", "base_url": "http://localhost:8080",
                                                     "outbound_program": out_prog}, token)
    S.http("PUT", f"/api/programs/{sender}", {"source": f"def main(i):\n    return ana.send('{conn}', 'base', {{'i': i}})\n"}, token)
    ids = []
    for i in range(n):
        ok, r = S.run(token, sender, {"i": i})
        if ok:
            ids.append(r)
        time.sleep(0.2)                                   # spread out: latency, not a burst
    end = time.time() + 60
    while time.time() < end and psql(f"SELECT count(*) FROM integration.outbox WHERE id IN ({','.join(map(str, ids))}) "
                                      "AND status = 'done'") != str(len(ids)):
        time.sleep(0.5)
    ms = [float(x) for x in psql(f"SELECT extract(epoch FROM done_at - created_at) * 1000 FROM integration.outbox "
                                  f"WHERE id IN ({','.join(map(str, ids))}) AND status = 'done'").split()]
    S.http("PUT", f"/api/admin/connectors/{conn}", {"kind": "webhook_in", "active": False}, token)
    return {"messages": len(ms), "p50_ms": pct(ms, 0.5), "p95_ms": pct(ms, 0.95)}, [out_prog, sender]


def execution_latency(token, tag, n):
    prog = f"test.base_echo_{tag}"
    S.http("PUT", f"/api/programs/{prog}", {"source": "def main(x=0):\n    return x\n"}, token)
    ms = []
    for i in range(n):
        t0 = time.perf_counter()
        S.run(token, prog, {"x": i})
        ms.append((time.perf_counter() - t0) * 1000)
    return {"runs": n, "p50_ms": pct(ms, 0.5), "p95_ms": pct(ms, 0.95)}, [prog]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--users", type=int, default=60)
    ap.add_argument("--seconds", type=int, default=60)
    ap.add_argument("--json")
    a = ap.parse_args()
    s, c = S.http("POST", "/api/session", {"username": "admin", "password": S.ADMIN_PASSWORD})
    token = c["token"]
    tag = str(int(time.time()))[-7:]
    S.http("PUT", "/api/admin/quotas/admin", {"max_concurrent": 0, "runs_per_minute": 0}, token)
    created = []
    try:
        result = {"label": a.label, "date": time.strftime("%Y-%m-%d %H:%M"),
                  "head": subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()}
        result["outbox"], p = outbox_latency(token, tag, 40); created += p
        result["execution"], p = execution_latency(token, tag, 100); created += p
        d = S.Data(token)
        acts = S.actions(d)
        step = S.step(token, acts, a.users, a.seconds, 8.0)
        result["load"] = {"users": a.users, "actions_per_s": step["per_second"], "errors": step["errors"],
                          "worst_interactive_p95_ms": step["worst_interactive_p95_ms"]}
        time.sleep(5)
        result["idle"] = metrics(token)
    finally:
        S.http("PUT", "/api/admin/quotas/admin", {"max_concurrent": None, "runs_per_minute": None}, token)
        for prog in created:
            S.http("DELETE", f"/api/programs/{prog}?purge=1", token=token)
    print(json.dumps(result, ensure_ascii=False))
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
