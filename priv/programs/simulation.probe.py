# ana:description Uso simulado: confere se uma esteira chegou ao estado esperado (a sonda que espera a automação)
# ana:menu no
"""Spec 067 (D4). The core asks it again and again (read-only) until the pipeline reaches the state or the time runs out —
then it is a finding: a pipeline that stopped where it should have gone on by itself."""

PARAMS = {"probe": {"type": "dict", "required": True, "label": "o que conferir"}}


def main(probe):
    if probe.get("flow"):
        rows = ana.sql("SELECT s.code, x.status, x.reason, x.error FROM flow.instance i "
                       "JOIN flow.instance_step x ON x.instance_id = i.id "
                       "JOIN flow.step s ON s.flow_code = i.flow_code AND s.seq = x.seq "
                       "WHERE i.flow_code = $1 AND i.doc_key = $2 ORDER BY x.seq", probe["flow"], str(probe["key"]))
        steps = {r["code"]: {"status": r["status"], "reason": r["reason"], "error": r["error"]} for r in rows}
        here = steps.get(probe["code"], {})
        return {"ok": here.get("status") in probe.get("statuses", ["done"]), "steps": steps,
                "failed": [c for c, x in steps.items() if x["status"] == "failed"]}
    raise ana.Error("UNKNOWN_PROBE", "sonda desconhecida")
