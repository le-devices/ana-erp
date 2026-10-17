# ana:description Processos: descobre o processo real pelos dados — variantes mais frequentes e desvios do modelo (etapa pulada, retrabalho, ordem trocada)
# ana:exposed yes
"""Spec 039 (RF-039-16, CA-039-08). to_model creates a draft (in a new process) from the most frequent variant."""

import datetime

from ana_lib.bpm import common

PARAMS = {"process": {"type": "str", "required": True, "label": "processo"},
          "days": {"type": "int", "default": 90, "label": "período (dias)"},
          "to_model": {"type": "str", "label": "criar rascunho num novo processo (código)"}}


def main(process, days=90, to_model=None):
    p = common.process(process)
    since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=max(1, int(days)))
    v = common.version(process, "published") or common.version(process)
    model = v["model"]
    names = {n["id"]: n.get("name", n["id"]) for n in model["nodes"]}
    reach = common.compile_model(model)["reach"] if not common.errors(common.validate(model, process)) or p["flow_code"] else {}
    if p["flow_code"]:
        rows = ana.sql(
            "SELECT i.id AS case_id, s.code AS node, x.how, x.finished_at, i.created_at AS started, i.finished_at AS ended "
            "FROM flow.instance_step x JOIN flow.instance i ON i.id = x.instance_id JOIN flow.step s ON s.flow_code = i.flow_code "
            "AND s.seq = x.seq WHERE i.flow_code = $1 AND i.created_at >= $2 AND x.status IN ('done', 'skipped') "
            "ORDER BY i.id, x.finished_at, x.seq LIMIT 200000", p["flow_code"], since)
    else:
        rows = ana.sql(
            "SELECT c.id AS case_id, t.node, t.how, t.finished_at, c.started_at AS started, c.finished_at AS ended "
            "FROM bpm.task t JOIN bpm.case c ON c.id = t.case_id WHERE c.process_code = $1 AND c.started_at >= $2 "
            "AND t.status = 'done' AND NOT (t.kind = 'rule' AND t.name IN ('Início', 'Junção')) "
            "ORDER BY c.id, t.finished_at, t.id LIMIT 200000", process, since)
    by_case = {}
    for r in rows:
        by_case.setdefault(r["case_id"], {"path": [], "skipped": [], "started": r["started"], "ended": r["ended"]})
        c = by_case[r["case_id"]]
        c["path"].append(r["node"])
        if r["how"] == "skipped":
            c["skipped"].append(r["node"])
    variants, deviations = {}, []
    for cid, c in by_case.items():
        key = tuple(c["path"])
        hours = (c["ended"] - c["started"]).total_seconds() / 3600 if c["ended"] else None
        va = variants.setdefault(key, {"count": 0, "hours": []})
        va["count"] += 1
        if hours is not None:
            va["hours"].append(hours)
        issues = []
        if c["skipped"]:
            issues.append({"kind": "skipped", "label": "etapa pulada", "nodes": c["skipped"]})
        rep = sorted({n for n in c["path"] if c["path"].count(n) > 1})
        if rep:
            issues.append({"kind": "rework", "label": "retrabalho", "nodes": rep})
        if reach:
            swapped = [f"{a}→{b}" for a, b in zip(c["path"], c["path"][1:]) if b not in reach.get(a, []) and a != b]
            if swapped:
                issues.append({"kind": "order", "label": "ordem fora do modelo", "nodes": swapped})
        if issues:
            deviations.append({"case": cid, "issues": issues})
    top = sorted(variants.items(), key=lambda kv: -kv[1]["count"])[:15]
    total = len(by_case)
    out = {"process": process, "cases": total,
           "variants": [{"path": list(k), "labels": [names.get(n, n) for n in k], "count": v_["count"],
                         "share_pct": round(100 * v_["count"] / total, 1) if total else 0,
                         "avg_h": round(sum(v_["hours"]) / len(v_["hours"]), 2) if v_["hours"] else None} for k, v_ in top],
           "deviations": deviations[:300],
           "deviation_counts": {k: sum(1 for d in deviations for i in d["issues"] if i["kind"] == k) for k in ("skipped", "rework", "order")}}
    if to_model and top:
        common.require_design()
        path = list(top[0][0])
        nodes = [{"id": "start", "type": "start", "name": "Início", "x": 60, "y": 90, "lane": "l1", "props": {"trigger": "manual"}}]
        for i, n in enumerate(path):
            nodes.append({"id": f"n{i + 1}", "type": "task_human", "name": names.get(n, n), "x": 60 + 170 * (i + 1), "y": 80,
                          "lane": "l1", "props": {}})
        nodes.append({"id": "end", "type": "end", "name": "Fim", "x": 60 + 170 * (len(path) + 1), "y": 90, "lane": "l1", "props": {}})
        edges = [{"id": f"e{i + 1}", "from": a["id"], "to": b["id"]} for i, (a, b) in enumerate(zip(nodes, nodes[1:]))]
        ana.call("bpm.save_process", code=to_model, name=f"{p['name']} (descoberto)", level="process",
                 objective=f"Desenhado a partir da variante mais frequente de {p['name']}")
        ana.call("bpm.save_model", process=to_model, model={"document": model.get("document", "none"), "run_as": "system",
                                                            "lanes": [{"id": "l1", "name": "Responsável", "role": "user"}],
                                                            "variables": [], "nodes": nodes, "edges": edges})
        out["created"] = to_model
    return out
