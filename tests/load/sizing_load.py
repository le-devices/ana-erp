# SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Sizing load test (official sizing table of deploy/INSTALL.md; baseline of spec 062, T-062-01).

Virtual users work like people: each one repeats a realistic mix of actions with a pause between
them (exponential, mean THINK_S seconds). The number of simultaneous users grows in steps; a step
passes when the p95 of every interactive action stays within the premium-experience budget
(P18: 1 s) and errors stay below 0.5 %. The capacity is the last step that passed.

Mix (weights): search a partner, open a partner sheet, open an order document, list routines and
categories, short report, credit report, create an order, invoice it. Writes are ~20 % of actions.

    ANA_URL=http://localhost:8080 python3 tests/load/sizing_load.py --steps 5,10,20,40,80 --step-seconds 60
Prints one JSON line per step and a summary; --json FILE also writes them.
"""

import argparse
import json
import os
import random
import statistics
import threading
import time
import urllib.error
import urllib.request

URL = os.environ.get("ANA_URL", "http://localhost:8080").rstrip("/")
ADMIN_PASSWORD = os.environ.get("ANA_ADMIN_PASSWORD", "admin")
BUDGET_MS = 1000          # P18: a screen opens within 1 s (p95)
MAX_ERRORS = 0.005


def http(method, path, body=None, token=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            text = r.read().decode()
            return r.status, (json.loads(text) if text else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
        return 0, str(e)


failures = {}


def run(token, program, params):
    s, c = http("POST", f"/api/programs/{program}/run", {"params": params}, token)
    ok = s == 200 and isinstance(c, dict) and "error" not in c
    if not ok:
        err = c.get("error", {}) if isinstance(c, dict) else {}
        key = f"{program}: {s} {err.get('code', '') if isinstance(err, dict) else ''}"
        with lock:
            failures.setdefault(key, str(err.get("message") if isinstance(err, dict) else c)[:200])
    return ok, (c.get("result") if ok else c)


class Data:
    def __init__(self, token):
        q = lambda sql: http("POST", "/api/sql", {"sql": sql}, token)[1]["rows"]
        # Customers the credit policy would not block (a refusal is right, but it is not what is being measured).
        self.parties = [r[0] for r in q("SELECT id FROM base.party p WHERE active AND kind IN ('customer', 'both') "
                                        "AND NOT EXISTS (SELECT 1 FROM finance.credit_profile c WHERE c.party_id = p.id) "
                                        "AND NOT EXISTS (SELECT 1 FROM finance.bill b WHERE b.party_id = p.id AND b.status = 'open' "
                                        "                AND b.due_date < current_date) "
                                        "ORDER BY random() LIMIT 300")]
        self.orders = [r[0] for r in q("SELECT number FROM sales.sales_order ORDER BY random() LIMIT 300")]
        # Items of the load test, created once with plenty of stock (orders never fail for lack of stock).
        self.items = [f"CARGA-{n}" for n in range(1, 6)]
        have = {r[0]: float(r[1]) for r in q("SELECT p.code, COALESCE(sum(m.quantity), 0) FROM base.product p "
                                             "LEFT JOIN inventory.stock_movement m ON m.product_id = p.id "
                                             "WHERE p.code LIKE 'CARGA-%' GROUP BY p.code")}
        for code in self.items:
            if code not in have:
                run(token, "base.save_product", {"code": code, "description": f"Item do teste de carga {code}", "price": "10"})
            if have.get(code, 0) < 100000:
                run(token, "inventory.stock_in", {"product": code, "quantity": 1000000, "warehouse": "CENTRAL"})
        self.words = ["silva", "comercial", "industria", "ltda", "tech", "servicos", "santos", "brasil", "norte", "sul"]


def actions(d):
    """(name, weight, interactive, function(token) -> ok)."""
    def search(t): return run(t, "master.search", {"entity": "party", "q": random.choice(d.words)})[0]
    def sheet(t): return run(t, "master.get", {"entity": "party", "key": str(random.choice(d.parties))})[0]
    def document(t): return run(t, "docs.view", {"kind": "order", "key": str(random.choice(d.orders))})[0]
    def home(t):
        s, c = http("GET", "/api/programs", token=t)
        if s != 200:
            with lock:
                failures.setdefault(f"GET /api/programs: {s}", str(c)[:200])
        return s == 200
    def short_report(t): return run(t, "sales.shortages", {})[0]
    def credit(t): return run(t, "finance.credit_report", {})[0]

    def order(t):
        ok, r = run(t, "sales.create_order", {"customer": random.choice(d.parties),
                                              "items": [{"product": random.choice(d.items), "quantity": 1}]})
        if ok and isinstance(r, dict) and r.get("number"):
            with lock:
                created.append(r["number"])
        return ok

    def invoice(t):
        with lock:
            number = created.pop() if created else None
        if number is None:
            return order(t)
        return run(t, "sales.invoice_order", {"number": number})[0]

    return [("buscar parceiro", 20, True, search), ("abrir ficha", 15, True, sheet), ("abrir documento", 15, True, document),
            ("tela inicial", 15, True, home), ("relatório curto", 8, True, short_report), ("relatório de crédito", 7, False, credit),
            ("criar pedido", 12, True, order), ("faturar pedido", 8, True, invoice)]


lock = threading.Lock()
created = []


def user(token, acts, think, stop, samples):
    names = [a for a in acts]
    weights = [a[1] for a in acts]
    time.sleep(random.uniform(0, think))                # users do not start in step
    while not stop.is_set():
        name, _, interactive, fn = random.choices(names, weights)[0]
        t0 = time.perf_counter()
        try:
            ok = fn(token)
        except Exception as e:                          # the load generator never stops on one failure
            ok = False
            with lock:
                failures.setdefault(f"{name}: {type(e).__name__}", str(e)[:200])
        ms = (time.perf_counter() - t0) * 1000
        with lock:
            samples.append((name, interactive, ok, ms))
        stop.wait(random.expovariate(1 / think))


def pct(values, p):
    if not values:
        return None
    v = sorted(values)
    return round(v[min(len(v) - 1, int(len(v) * p))], 1)


def step(token, acts, users, seconds, think):
    samples, stop = [], threading.Event()
    threads = [threading.Thread(target=user, args=(token, acts, think, stop, samples), daemon=True) for _ in range(users)]
    for t in threads:
        t.start()
    time.sleep(seconds)
    stop.set()
    for t in threads:
        t.join(timeout=90)
    by = {}
    for name, inter, ok, ms in samples:
        by.setdefault(name, {"interactive": inter, "ms": [], "errors": 0})
        by[name]["ms"].append(ms)
        by[name]["errors"] += 0 if ok else 1
    total = len(samples)
    errors = sum(1 for s in samples if not s[2])
    per = {n: {"n": len(v["ms"]), "p50": pct(v["ms"], 0.5), "p95": pct(v["ms"], 0.95), "errors": v["errors"],
               "interactive": v["interactive"]} for n, v in by.items()}
    worst = max((v["p95"] for v in per.values() if v["interactive"] and v["p95"] is not None), default=None)
    passed = total > 0 and worst is not None and worst <= BUDGET_MS and errors / total <= MAX_ERRORS
    return {"users": users, "seconds": seconds, "actions": total, "per_second": round(total / seconds, 1),
            "errors": errors, "worst_interactive_p95_ms": worst, "passed": passed, "per_action": per}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", default="5,10,20,40,80")
    ap.add_argument("--step-seconds", type=int, default=60)
    ap.add_argument("--think", type=float, default=8.0, help="mean pause between a user's actions (s)")
    ap.add_argument("--label", default="")
    ap.add_argument("--json")
    a = ap.parse_args()
    s, c = http("POST", "/api/session", {"username": "admin", "password": ADMIN_PASSWORD})
    assert s == 200, c
    token = c["token"]
    # Per-user quotas would measure the quota, not the hardware: lifted for the run, restored at the end.
    http("PUT", "/api/admin/quotas/admin", {"max_concurrent": 0, "runs_per_minute": 0}, token)
    out = []
    try:
        d = Data(token)
        assert d.parties and d.orders and d.items, "dados insuficientes para o teste (parceiros, pedidos, itens com saldo)"
        acts = actions(d)
        run(token, "master.search", {"entity": "party", "q": "aquecimento"})            # warm-up
        for users in [int(x) for x in a.steps.split(",")]:
            r = step(token, acts, users, a.step_seconds, a.think)
            r["label"] = a.label
            out.append(r)
            print(json.dumps(r, ensure_ascii=False), flush=True)
            if not r["passed"]:
                break
    finally:
        http("PUT", "/api/admin/quotas/admin", {"max_concurrent": None, "runs_per_minute": None}, token)
    capacity = max((r["users"] for r in out if r["passed"]), default=0)
    summary = {"label": a.label, "capacity_users": capacity, "think_s": a.think, "budget_ms": BUDGET_MS, "steps": out,
               "failures": failures}
    print(json.dumps({"label": a.label, "capacity_users": capacity, "failures": failures}, ensure_ascii=False))
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(summary, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
