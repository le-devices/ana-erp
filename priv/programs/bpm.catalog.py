# ana:description Processos: mapa da empresa (cadeia de valor → processos → subprocessos) com dono, situação e indicadores
# ana:exposed yes
# ana:command processos
"""Spec 039 (RF-039-01, H1). One row per process with its published version, open cases and late tasks."""

from ana_lib.bpm import common

PARAMS = {"q": {"type": "str", "label": "buscar"}}


def main(q=None):
    rows = ana.sql(
        "SELECT p.code, p.name, p.parent_code, p.level, p.owner, p.objective, p.kpi, p.tags, p.flow_code, p.active, p.position, "
        "  (SELECT max(version) FROM bpm.version v WHERE v.process_code = p.code AND v.status = 'published') AS published, "
        "  EXISTS (SELECT 1 FROM bpm.version v WHERE v.process_code = p.code AND v.status = 'draft') AS has_draft, "
        "  CASE WHEN p.flow_code IS NULL THEN (SELECT count(*) FROM bpm.case c WHERE c.process_code = p.code "
        "                                        AND c.status IN ('running', 'waiting', 'failed')) "
        "       ELSE (SELECT count(*) FROM flow.instance i WHERE i.flow_code = p.flow_code AND i.status IN ('running', 'waiting', 'failed')) "
        "  END AS open_cases, "
        "  (SELECT count(*) FROM bpm.task t JOIN bpm.case c ON c.id = t.case_id WHERE c.process_code = p.code "
        "     AND t.status = 'waiting' AND t.due_at < now()) AS late "
        "FROM bpm.process p WHERE ($1::text IS NULL OR base.norm(p.name || ' ' || p.code) LIKE '%' || base.norm($1) || '%') "
        "ORDER BY p.position, p.name", q)
    return {"processes": rows, "can_design": common.can_design(),
            "types": [{"type": k, **v} for k, v in common.TYPES.items()]}
