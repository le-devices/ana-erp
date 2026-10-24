# ana:description Processos: painel de um processo — casos, prazo médio e de 90 % contra a meta, vazão por semana e mapa de calor por elemento
# ana:exposed yes
# ana:category Processos/Acompanhamento
"""Spec 039 (RF-039-15). For esteiras the numbers come from their steps (same engine, spec 030)."""

import datetime

from ana_lib.bpm import common
from ana_lib.bpm import sim

PARAMS = {"process": {"type": "str", "required": True, "label": "processo"},
          "days": {"type": "int", "default": 90, "label": "período (dias)"}}


def main(process, days=90):
    p = common.process(process)
    since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=max(1, int(days)))
    if p["flow_code"]:
        cases = ana.sql_one(
            "SELECT count(*) AS started, count(*) FILTER (WHERE status = 'done') AS done, "
            "  count(*) FILTER (WHERE status IN ('running', 'waiting', 'failed')) AS open, "
            "  count(*) FILTER (WHERE status = 'failed') AS failed, 0 AS late "
            "FROM flow.instance WHERE flow_code = $1 AND created_at >= $2", p["flow_code"], since)
        cycles = [float(r["h"]) for r in ana.sql(
            "SELECT extract(epoch FROM finished_at - created_at) / 3600 AS h FROM flow.instance WHERE flow_code = $1 "
            "AND created_at >= $2 AND status = 'done'", p["flow_code"], since)]
        weekly = ana.sql("SELECT date_trunc('week', finished_at)::date AS week, count(*) AS done FROM flow.instance "
                         "WHERE flow_code = $1 AND status = 'done' AND finished_at >= now() - interval '12 weeks' GROUP BY 1 ORDER BY 1",
                         p["flow_code"])
        heat = ana.sql(
            "SELECT s.code AS node, count(*) FILTER (WHERE x.status IN ('done', 'skipped')) AS count, "
            "  avg(extract(epoch FROM x.finished_at - COALESCE(x.started_at, x.finished_at)) / 3600) "
            "     FILTER (WHERE x.status = 'done') AS avg_h, "
            "  count(*) FILTER (WHERE x.status = 'failed') AS failed, count(*) FILTER (WHERE x.status IN ('waiting', 'ready', 'running')) AS open, "
            "  0 AS late FROM flow.instance_step x JOIN flow.instance i ON i.id = x.instance_id "
            "JOIN flow.step s ON s.flow_code = i.flow_code AND s.seq = x.seq WHERE i.flow_code = $1 AND i.created_at >= $2 GROUP BY s.code",
            p["flow_code"], since)
    else:
        cases = ana.sql_one(
            "SELECT count(*) AS started, count(*) FILTER (WHERE status = 'done') AS done, "
            "  count(*) FILTER (WHERE status IN ('running', 'waiting', 'failed')) AS open, "
            "  count(*) FILTER (WHERE status = 'failed') AS failed, "
            "  (SELECT count(DISTINCT t.case_id) FROM bpm.task t JOIN bpm.case c2 ON c2.id = t.case_id WHERE c2.process_code = $1 "
            "     AND t.status = 'waiting' AND t.due_at < now()) AS late "
            "FROM bpm.case WHERE process_code = $1 AND started_at >= $2 AND parent_task IS NULL", process, since)
        cycles = [float(r["h"]) for r in ana.sql(
            "SELECT extract(epoch FROM finished_at - started_at) / 3600 AS h FROM bpm.case WHERE process_code = $1 "
            "AND started_at >= $2 AND status = 'done'", process, since)]
        weekly = ana.sql("SELECT date_trunc('week', finished_at)::date AS week, count(*) AS done FROM bpm.case "
                         "WHERE process_code = $1 AND status = 'done' AND finished_at >= now() - interval '12 weeks' GROUP BY 1 ORDER BY 1",
                         process)
        heat = ana.sql(
            "SELECT t.node, count(*) FILTER (WHERE t.status = 'done') AS count, "
            "  avg(extract(epoch FROM t.finished_at - t.created_at) / 3600) FILTER (WHERE t.status = 'done') AS avg_h, "
            "  count(*) FILTER (WHERE t.status = 'failed') AS failed, "
            "  count(*) FILTER (WHERE t.status IN ('waiting', 'ready', 'running')) AS open, "
            "  count(*) FILTER (WHERE t.escalated OR (t.due_at IS NOT NULL AND COALESCE(t.finished_at, now()) > t.due_at)) AS late "
            "FROM bpm.task t JOIN bpm.case c ON c.id = t.case_id WHERE c.process_code = $1 AND c.started_at >= $2 "
            "AND NOT (t.kind = 'rule' AND t.name IN ('Início', 'Junção')) GROUP BY t.node", process, since)
    target = (p["kpi"] or {}).get("cycle_hours")
    on_time = round(100 * sum(1 for c in cycles if c <= float(target)) / len(cycles), 1) if target and cycles else None
    return {"process": process, "days": days, "cases": cases,
            "cycle_h": {"avg": round(sum(cycles) / len(cycles), 2) if cycles else None,
                        "p90": round(sim.percentile(cycles, 0.9), 2) if cycles else None, "target": target, "on_time_pct": on_time},
            "weekly": weekly,
            "heat": {r["node"]: {"count": r["count"], "avg_h": round(float(r["avg_h"]), 2) if r["avg_h"] is not None else None,
                                 "failed": r["failed"], "open": r["open"], "late": r["late"]} for r in heat}}
