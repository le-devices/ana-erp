# ana:description Processos: calibra a simulação pela realidade — durações, caminhos e chegadas medidos nos casos e documentos do ERP
# ana:exposed yes
# ana:category Processos/Simulação e descoberta
"""Spec 039 (RF-039-10, CA-039-05). Durations are the observed lead times of each element (empirical
distribution: the simulation reproduces the real mean), probabilities come from the paths taken,
arrivals from the cases started. Time in calendar hours (hours_per_day = 24) with ample capacity: the
observed waiting is already inside the durations. Works for processes and esteiras."""

import datetime

from ana_lib.bpm import common
from ana_lib.bpm import sim

PARAMS = {"process": {"type": "str", "required": True, "label": "processo"},
          "days": {"type": "int", "default": 90, "label": "período (dias para trás)"},
          "apply": {"type": "bool", "default": False, "label": "gravar no rascunho como parâmetros de simulação"}}
MAX_SAMPLES = 400


def main(process, days=90, apply=False):
    p = common.process(process)
    since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=max(1, int(days)))
    if p["flow_code"]:
        durations, visits, starts, real = esteira(p["flow_code"], since)
    else:
        durations, visits, starts, real = bpm_cases(process, since)
    v = common.version(process, "published") or common.version(process)
    model = v["model"]
    probs = {}
    for n in model["nodes"]:
        if n["type"] in ("gw_xor", "gw_or"):
            outs = [e for e in model["edges"] if e["from"] == n["id"] and not e.get("on")]
            total = sum(visits.get(e["to"], 0) for e in outs)
            if total:
                for e in outs:
                    probs[e["id"]] = round(visits.get(e["to"], 0) / total, 4)
    params = {"hours_per_day": 24, "days": max(1, int(days)), "arrivals_per_day": round(starts / max(1, int(days)), 4),
              "runs": 5, "seed": 42, "probabilities": probs,
              "durations": {k: {"dist": "empirical", "values": [round(x, 4) for x in xs[:MAX_SAMPLES]]} for k, xs in durations.items() if xs},
              "resources": {l["id"]: {"count": 999, "cost_hour": 0} for l in model.get("lanes") or []}}
    quality = {k: {"samples": len(xs), "avg_h": round(sum(xs) / len(xs), 2), "p90_h": round(sim.percentile(xs, 0.9), 2)}
               for k, xs in durations.items() if xs}
    out = {"process": process, "params": params, "quality": quality, "cases_started": starts,
           "real_cycle_h": round(sum(real) / len(real), 3) if real else None, "real_cases": len(real)}
    if apply:
        common.require_design()
        d = common.version(process, "draft")
        if d:
            ana.sql_exec("UPDATE bpm.version SET sim = $3, updated_at = now() WHERE process_code = $1 AND version = $2",
                         process, d["version"], params)
            out["applied_to"] = d["version"]
    return out


def bpm_cases(process, since):
    rows = ana.sql("SELECT t.node, extract(epoch FROM t.finished_at - t.created_at) / 3600 AS h FROM bpm.task t "
                   "JOIN bpm.case c ON c.id = t.case_id WHERE c.process_code = $1 AND c.started_at >= $2 AND t.status = 'done' "
                   "AND t.kind <> 'rule' ORDER BY t.id DESC LIMIT 50000", process, since)
    durations = {}
    for r in rows:
        durations.setdefault(r["node"], []).append(float(r["h"] or 0))
    visits = {r["node"]: r["n"] for r in ana.sql(
        "SELECT e.node, count(*) AS n FROM bpm.event e JOIN bpm.case c ON c.id = e.case_id WHERE c.process_code = $1 "
        "AND c.started_at >= $2 AND e.kind IN ('enter', 'end') GROUP BY e.node", process, since)}
    starts = ana.sql_value("SELECT count(*) FROM bpm.case WHERE process_code = $1 AND started_at >= $2 AND parent_task IS NULL",
                           process, since)
    real = [float(r["h"]) for r in ana.sql(
        "SELECT extract(epoch FROM finished_at - started_at) / 3600 AS h FROM bpm.case WHERE process_code = $1 "
        "AND started_at >= $2 AND status = 'done' LIMIT 50000", process, since)]
    return durations, visits, starts, real


def esteira(flow, since):
    rows = ana.sql(
        "SELECT s.code AS node, extract(epoch FROM x.finished_at - COALESCE(lag(x.finished_at) OVER w, i.created_at)) / 3600 AS h "
        "FROM flow.instance_step x JOIN flow.instance i ON i.id = x.instance_id JOIN flow.step s ON s.flow_code = i.flow_code "
        "AND s.seq = x.seq WHERE i.flow_code = $1 AND i.created_at >= $2 AND x.status IN ('done', 'skipped') "
        "WINDOW w AS (PARTITION BY x.instance_id ORDER BY x.seq) LIMIT 50000", flow, since)
    durations = {}
    for r in rows:
        durations.setdefault(r["node"], []).append(max(0.0, float(r["h"] or 0)))
    starts = ana.sql_value("SELECT count(*) FROM flow.instance WHERE flow_code = $1 AND created_at >= $2", flow, since)
    real = [float(r["h"]) for r in ana.sql(
        "SELECT extract(epoch FROM finished_at - created_at) / 3600 AS h FROM flow.instance WHERE flow_code = $1 "
        "AND created_at >= $2 AND status = 'done' LIMIT 50000", flow, since)]
    return durations, {}, starts, real
