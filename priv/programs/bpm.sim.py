# ana:description BPM: simulador de eventos discretos (chegadas, durações, caminhos, pessoas por raia, custo) com repetições e semente
# ana:kind library
"""Spec 039 (RF-039-08, CA-039-04). Time in hours. Cases arrive (Poisson) during the horizon; every
element takes a sampled duration; people's tasks wait for a free person of their lane (FIFO); decisions
follow the given probabilities; joins wait while another token of the case can still reach them (the
same rule as the engine). Same seed, same result."""

import heapq
import math
import random

DEFAULT = {"task_human": {"dist": "triangular", "min": 0.5, "mode": 1, "max": 2},
           "task_approval": {"dist": "triangular", "min": 0.25, "mode": 0.5, "max": 1},
           "task_auto": {"dist": "fixed", "value": 0.02}, "task_send": {"dist": "fixed", "value": 0.02},
           "task_rule": {"dist": "fixed", "value": 0}, "event_fact": {"dist": "exponential", "mean": 8},
           "subprocess": {"dist": "triangular", "min": 2, "mode": 4, "max": 8}}
PEOPLE = {"task_human", "task_approval"}
MAX_EVENTS = 3_000_000


def sample(rng, d):
    k = d.get("dist", "fixed")
    if k == "fixed":
        return max(0.0, float(d.get("value", 0)))
    if k == "uniform":
        return rng.uniform(float(d["min"]), float(d["max"]))
    if k == "triangular":
        a, c, b = float(d["min"]), float(d.get("mode", d["min"])), float(d["max"])
        return rng.triangular(a, b, min(max(c, a), b)) if b > a else a
    if k == "exponential":
        m = float(d.get("mean", 1))
        return rng.expovariate(1 / m) if m > 0 else 0.0
    if k == "empirical":
        vals = d.get("values") or [0]
        return float(vals[rng.randrange(len(vals))])
    raise ValueError(f"distribuição desconhecida: {k}")


def percentile(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    f, c = math.floor(k), math.ceil(k)
    return xs[f] if f == c else xs[f] + (xs[c] - xs[f]) * (k - f)


class Model:
    def __init__(self, model, reach):
        self.nodes = {n["id"]: n for n in model["nodes"]}
        self.out = {k: [] for k in self.nodes}
        self.inc = {k: 0 for k in self.nodes}
        for e in model["edges"]:
            self.out.setdefault(e["from"], []).append(e)
            self.inc[e["to"]] = self.inc.get(e["to"], 0) + 1
        self.reach = {k: set(v) for k, v in reach.items()}
        self.start = next(k for k, n in self.nodes.items() if n["type"] == "start")
        self.lane = {k: n.get("lane") for k, n in self.nodes.items()}


def run_once(m, params, rng, trace_cases=0):
    hours_day = float(params.get("hours_per_day", 8))
    horizon = float(params.get("days", 60)) * hours_day
    rate = float(params.get("arrivals_per_day", 10)) / hours_day          # per hour
    durations = params.get("durations") or {}
    probs = params.get("probabilities") or {}
    fixed = params.get("fixed_cost") or {}
    automate = set(params.get("automate") or [])
    resources = {}
    for lane_id, r in (params.get("resources") or {}).items():
        resources[lane_id] = {"count": max(1, int(r.get("count", 1))), "cost": float(r.get("cost_hour", 0)), "busy": 0,
                              "queue": [], "busy_time": 0.0, "max_queue": 0}
    events, seq = [], 0
    cases = {}
    node_wait, node_service, node_n = {}, {}, {}
    trace = []

    def push(t, kind, data):
        nonlocal seq
        seq += 1
        heapq.heappush(events, (t, seq, kind, data))

    def resource_of(node):
        lane = m.lane.get(node)
        if lane not in resources:
            resources[lane] = {"count": 1, "cost": 0.0, "busy": 0, "queue": [], "busy_time": 0.0, "max_queue": 0}
        return lane, resources[lane]

    def duration(node):
        n = m.nodes[node]
        if node in durations:
            return sample(rng, durations[node])
        if n["type"] == "timer":
            return float((n.get("props") or {}).get("hours", 1) or 1)
        if n["type"] in PEOPLE and node in automate:
            return sample(rng, DEFAULT["task_auto"])
        return sample(rng, DEFAULT.get(n["type"], {"dist": "fixed", "value": 0}))

    def route(case, node):
        n = m.nodes[node]
        outs = [e for e in m.out.get(node, []) if not e.get("on")]
        errs = [e for e in m.out.get(node, []) if e.get("on") == "error" and e["id"] in probs]
        for e in errs:                                     # failure rate of a task, when given
            if rng.random() < float(probs[e["id"]]):
                return [e["to"]]
        if not outs:
            return []
        if n["type"] == "gw_xor" and len(outs) > 1:
            given = {e["id"]: float(probs[e["id"]]) for e in outs if e["id"] in probs}
            rest = [e for e in outs if e["id"] not in given]
            left = max(0.0, 1 - sum(given.values()))
            weights = [given.get(e["id"], left / len(rest) if rest else 0) for e in outs]
            if sum(weights) <= 0:
                weights = [1] * len(outs)
            r, acc = rng.random() * sum(weights), 0.0
            for e, w in zip(outs, weights):
                acc += w
                if r <= acc:
                    return [e["to"]]
            return [outs[-1]["to"]]
        if n["type"] == "gw_or" and len(outs) > 1:
            taken = [e["to"] for e in outs if not e.get("default") and rng.random() < float(probs.get(e["id"], 0.5))]
            return taken or [e["to"] for e in outs if e.get("default")] or [outs[0]["to"]]
        return [e["to"] for e in outs]

    def arrive_token(t, case, node):
        n = m.nodes[node]
        typ = n["type"]
        c = cases[case]
        if typ == "end":
            c["tokens"] -= 1
            if c["tokens"] == 0:
                c["end"] = t
            return
        if typ.startswith("gw_") and m.inc.get(node, 0) >= 2:
            c["joining"][node] = c["joining"].get(node, 0) + 1
            c["tokens"] -= 1
            check_join(t, case, node)
            return
        if typ in ("start", "annotation") or typ.startswith("gw_"):
            nxt = route(case, node)
            c["tokens"] += len(nxt) - 1
            for to in nxt:
                c["at"].setdefault(to, 0)
                arrive_token(t, case, to)
            if not nxt and c["tokens"] == 0:
                c["end"] = t
            return
        c["active"][node] = c["active"].get(node, 0) + 1
        if typ in PEOPLE and node not in automate:
            lane, r = resource_of(node)
            if r["busy"] < r["count"]:
                start_service(t, case, node, t)
            else:
                r["queue"].append((case, node, t))
                r["max_queue"] = max(r["max_queue"], len(r["queue"]))
        else:
            d = duration(node)
            record(node, 0.0, d)
            c["cost"] += float(fixed.get(node, 0))
            if trace_cases and case < trace_cases:
                trace.append([case, node, round(t, 3), round(t + d, 3)])
            push(t + d, "done", (case, node, None))

    def check_join(t, case, node):
        c = cases[case]
        blocking = [k for k, v in c["active"].items() if v > 0 and node in m.reach.get(k, ())]
        blocking += [k for k, v in c["joining"].items() if v > 0 and k != node and node in m.reach.get(k, ())]
        if blocking:
            return
        c["joining"][node] = 0
        c["tokens"] += 1
        nxt = route(case, node)
        c["tokens"] += len(nxt) - 1
        for to in nxt:
            arrive_token(t, case, to)
        if not nxt and c["tokens"] == 0:
            c["end"] = t

    def start_service(t, case, node, queued_at):
        lane, r = resource_of(node)
        r["busy"] += 1
        d = duration(node)
        r["busy_time"] += d
        record(node, t - queued_at, d)
        cases[case]["cost"] += d * r["cost"] + float(fixed.get(node, 0))
        if trace_cases and case < trace_cases:
            trace.append([case, node, round(queued_at, 3), round(t + d, 3)])
        push(t + d, "done", (case, node, lane))

    def record(node, wait, service):
        node_wait[node] = node_wait.get(node, 0.0) + wait
        node_service[node] = node_service.get(node, 0.0) + service
        node_n[node] = node_n.get(node, 0) + 1

    t, n_case = 0.0, 0
    if rate > 0:
        push(rng.expovariate(rate), "arrive", None)
    processed = 0
    while events:
        t, _, kind, data = heapq.heappop(events)
        processed += 1
        if processed > MAX_EVENTS:
            raise ValueError("simulação grande demais: reduza dias, chegadas ou repetições")
        if kind == "arrive":
            if t > horizon:
                continue
            cases[n_case] = {"start": t, "end": None, "tokens": 1, "active": {}, "joining": {}, "cost": 0.0, "at": {}}
            arrive_token(t, n_case, m.start)
            n_case += 1
            push(t + rng.expovariate(rate), "arrive", None)
        else:
            case, node, lane = data
            c = cases[case]
            c["active"][node] -= 1
            if lane is not None:
                r = resources[lane]
                r["busy"] -= 1
                if r["queue"]:
                    qc, qn, qt = r["queue"].pop(0)
                    start_service(t, qc, qn, qt)
            nxt = route(case, node)
            c["tokens"] += len(nxt) - 1
            for to in nxt:
                arrive_token(t, case, to)
            if not nxt and c["tokens"] <= 0:
                c["end"] = t
            for j, v in list(c["joining"].items()):
                if v > 0:
                    check_join(t, case, j)
    done = [c for c in cases.values() if c["end"] is not None]
    end_time = max(t, horizon)
    return {"cases": len(cases), "done": len(done), "cycle": [c["end"] - c["start"] for c in done],
            "cost": [c["cost"] for c in done], "wip": len(cases) - len(done),
            "node_wait": node_wait, "node_service": node_service, "node_n": node_n,
            "resources": {k: {"count": r["count"], "utilization": r["busy_time"] / (r["count"] * end_time) if end_time else 0,
                              "max_queue": r["max_queue"], "cost_hour": r["cost"]} for k, r in resources.items()},
            "trace": trace}


def simulate(model, reach, params):
    m = Model(model, reach)
    runs = max(1, min(int(params.get("runs", 5)), 50))
    seed = int(params.get("seed", 42))
    hours_day = float(params.get("hours_per_day", 8))
    days = float(params.get("days", 60))
    if days * float(params.get("arrivals_per_day", 10)) * runs > 1_000_000:
        raise ValueError("simulação grande demais: até 1 milhão de casos somando as repetições")
    all_cycle, all_cost, per_run = [], [], []
    agg_wait, agg_service, agg_n, util = {}, {}, {}, {}
    trace = []
    for i in range(runs):
        rng = random.Random(seed * 1000 + i)
        r = run_once(m, params, rng, trace_cases=40 if i == 0 else 0)
        if i == 0:
            trace = r["trace"][:3000]
        all_cycle += r["cycle"]
        all_cost += r["cost"]
        per_run.append({"cases": r["cases"], "done": r["done"], "wip": r["wip"],
                        "cycle_avg": sum(r["cycle"]) / len(r["cycle"]) if r["cycle"] else None})
        for k, v in r["node_wait"].items():
            agg_wait[k] = agg_wait.get(k, 0) + v
            agg_service[k] = agg_service.get(k, 0) + r["node_service"][k]
            agg_n[k] = agg_n.get(k, 0) + r["node_n"][k]
        for k, v in r["resources"].items():
            u = util.setdefault(k, {"utilization": 0.0, "max_queue": 0, "count": v["count"], "cost_hour": v["cost_hour"]})
            u["utilization"] += v["utilization"] / runs
            u["max_queue"] = max(u["max_queue"], v["max_queue"])
    nodes = {k: {"name": m.nodes[k].get("name", k), "visits": round(agg_n[k] / runs, 1),
                 "wait_h": round(agg_wait[k] / agg_n[k], 3), "service_h": round(agg_service[k] / agg_n[k], 3)}
             for k in agg_n}
    done = sum(r["done"] for r in per_run)
    weeks = days / 5 if hours_day < 24 else days / 7
    lanes = {l["id"]: l.get("name", l["id"]) for l in model.get("lanes") or []}
    bottleneck = None
    if util:
        lane, u = max(util.items(), key=lambda kv: kv[1]["utilization"])
        if u["utilization"] >= 0.8:
            bottleneck = {"kind": "lane", "id": lane, "name": lanes.get(lane, lane), "utilization": round(u["utilization"], 3)}
    if not bottleneck and nodes:
        k, v = max(nodes.items(), key=lambda kv: kv[1]["wait_h"])
        if v["wait_h"] > 0:
            bottleneck = {"kind": "node", "id": k, "name": v["name"], "wait_h": v["wait_h"]}
    unit = hours_day
    return {
        "runs": runs, "seed": seed, "cases": round(sum(r["cases"] for r in per_run) / runs, 1),
        "done": round(done / runs, 1), "wip_end": round(sum(r["wip"] for r in per_run) / runs, 1),
        "cycle_h": {"avg": _r(sum(all_cycle) / len(all_cycle)) if all_cycle else None,
                    "p50": _r(percentile(all_cycle, 0.5)), "p90": _r(percentile(all_cycle, 0.9))},
        "cycle_days": {"avg": _r(sum(all_cycle) / len(all_cycle) / unit) if all_cycle else None,
                       "p50": _r((percentile(all_cycle, 0.5) or 0) / unit) if all_cycle else None,
                       "p90": _r((percentile(all_cycle, 0.9) or 0) / unit) if all_cycle else None},
        "cost_per_case": _r(sum(all_cost) / len(all_cost)) if all_cost else None,
        "throughput_week": _r(done / runs / weeks) if weeks else None,
        "nodes": nodes,
        "lanes": {k: {"name": lanes.get(k, k), "count": v["count"], "utilization": round(v["utilization"], 3),
                      "max_queue": v["max_queue"], "cost_hour": v["cost_hour"]} for k, v in util.items()},
        "bottleneck": bottleneck, "per_run": per_run, "trace": trace,
    }


def _r(v):
    return None if v is None else round(v, 3)
