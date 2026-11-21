# SPDX-FileCopyrightText: 2026 LE Devices
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Load test of the public API (spec 010, RNF-010-14 / CA-010-11).

Target: 1,000 calls/s of a trivial program per 4-vCPU node, p95 < 50 ms.
It creates a robot, a trivial exposed program and an API client without practical limits, gets a token and
calls /rpc from several processes over keep-alive connections, then reports throughput and latency
percentiles. Everything it creates is removed at the end.

    ANA_URL=http://localhost:8080 python3 tests/load/public_api_load.py [--seconds 20] [--workers 16]
    --assert  exits 1 when the target is not met (use on reference hardware: 4 vCPUs per node)
"""

import argparse
import base64
from http import client as httpc
import json
import multiprocessing as mp
import os
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

URL = os.environ.get("ANA_URL", "http://localhost:8080").rstrip("/")
ADMIN_PASSWORD = os.environ.get("ANA_ADMIN_PASSWORD", "admin")
TARGET_RPS, TARGET_P95_MS = 1000, 50


def http(method, path, body=None, token=None, headers=None, raw=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(URL + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            text = r.read().decode()
            return r.status, (json.loads(text) if text else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def setup():
    s, c = http("POST", "/api/session", {"username": "admin", "password": ADMIN_PASSWORD})
    assert s == 200, c
    admin = c["token"]
    tag = str(int(time.time()))[-8:]
    robot, program = f"carga{tag}", f"test.carga{tag}.eco"
    s, c = http("POST", "/api/admin/users", {"username": robot, "kind": "robot", "role": "user"}, admin)
    assert s == 200, c
    s, c = http("PUT", f"/api/programs/{program}", {"source": "def main(n=0):\n    return n\n", "exposed": True}, admin)
    assert s == 200, c
    s, c = http("POST", "/api/admin/api-clients", {"name": "Teste de carga", "run_as": robot, "scopes": [program],
                                                   "rate_per_minute": 1000000}, admin)
    assert s == 200, c
    client = c
    form = urllib.parse.urlencode({"grant_type": "client_credentials"}).encode()
    basic = base64.b64encode(f"{client['client_id']}:{client['client_secret']}".encode()).decode()
    s, c = http("POST", "/oauth/token", raw=form, headers={"Content-Type": "application/x-www-form-urlencoded",
                                                           "Authorization": "Basic " + basic})
    assert s == 200, c
    return admin, robot, program, client, c["access_token"]


def teardown(admin, robot, program, client):
    http("PUT", f"/api/admin/api-clients/{client['client_id']}", {"active": False}, admin)
    http("DELETE", f"/api/programs/{program}?purge=1", token=admin)
    http("PUT", f"/api/admin/users/{robot}", {"active": False}, admin)


def worker(token, program, until, out):
    try:
        out.put(run_worker(token, program, until))
    except Exception:  # noqa: BLE001 - the parent must never wait forever
        out.put(([], 1))


def run_worker(token, program, until):
    u = urllib.parse.urlparse(URL)
    conn = httpc.HTTPConnection(u.hostname, u.port or 80, timeout=30)
    body = json.dumps({"jsonrpc": "2.0", "method": program, "params": {"n": 1}, "id": 1})
    hdr = {"Content-Type": "application/json", "Authorization": "Bearer " + token}
    lat, errors = [], 0
    while time.time() < until:
        t0 = time.perf_counter()
        try:
            conn.request("POST", "/rpc", body, hdr)
            r = conn.getresponse()
            data = r.read()
            ok = r.status == 200 and b'"result":1' in data
        except (OSError, httpc.HTTPException):
            ok = False
            conn.close()
            conn = httpc.HTTPConnection(u.hostname, u.port or 80, timeout=30)
        lat.append((time.perf_counter() - t0) * 1000)
        errors += 0 if ok else 1
    return lat, errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=20)
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--assert", dest="check", action="store_true")
    a = ap.parse_args()
    admin, robot, program, client, token = setup()
    try:
        # Warm-up: caches, interpreter pool, connections.
        for _ in range(20):
            http("POST", "/rpc", {"jsonrpc": "2.0", "method": program, "params": {}, "id": 1}, token)
        out = mp.Queue()
        start = time.time()
        until = start + a.seconds
        procs = [mp.Process(target=worker, args=(token, program, until, out)) for _ in range(a.workers)]
        for p in procs:
            p.start()
        results = [out.get() for _ in procs]
        for p in procs:
            p.join()
        elapsed = time.time() - start
    finally:
        teardown(admin, robot, program, client)
    lat = sorted(x for r, _ in results for x in r)
    errors = sum(e for _, e in results)
    rps = len(lat) / elapsed
    q = statistics.quantiles(lat, n=100) if len(lat) >= 100 else [max(lat)] * 99
    report = {"calls": len(lat), "errors": errors, "seconds": round(elapsed, 1), "calls_per_s": round(rps),
              "p50_ms": round(q[49], 1), "p95_ms": round(q[94], 1), "p99_ms": round(q[98], 1),
              "workers": a.workers, "target": f"{TARGET_RPS}/s p95<{TARGET_P95_MS}ms"}
    print(json.dumps(report, indent=2))
    met = errors == 0 and rps >= TARGET_RPS and q[94] < TARGET_P95_MS
    print("META ATINGIDA" if met else "meta não atingida neste equipamento")
    if a.check and not met:
        sys.exit(1)


if __name__ == "__main__":
    main()
