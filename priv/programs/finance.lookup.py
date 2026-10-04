# ana:description Opções para campos de escolha do financeiro
# ana:kind program
# ana:menu no
"""Lookup for forms: [{"value", "label"}]. kind: cost_centers | accounts | rules."""

PARAMS = {"kind": {"type": "str", "required": True, "choices": ["cost_centers", "accounts", "rules"]}}


def main(kind):
    if kind == "cost_centers":
        rows = ana.sql("WITH RECURSIVE t AS (SELECT code, name, parent_code, 0 AS depth, code::text AS path "
                       "  FROM finance.cost_center WHERE parent_code IS NULL AND active "
                       "  UNION ALL SELECT c.code, c.name, c.parent_code, t.depth + 1, t.path || '/' || c.code "
                       "  FROM finance.cost_center c JOIN t ON c.parent_code = t.code WHERE c.active) "
                       "SELECT code, name, depth FROM t ORDER BY path")
        return [{"value": r["code"], "label": "  " * r["depth"] + f"{r['code']} — {r['name']}"} for r in rows]
    if kind == "accounts":
        rows = ana.sql("SELECT code, description FROM finance.account WHERE postable ORDER BY code")
        return [{"value": r["code"], "label": f"{r['code']} {r['description']}"} for r in rows]
    rows = ana.sql("SELECT code, name FROM finance.allocation_rule WHERE active ORDER BY code")
    return [{"value": r["code"], "label": f"{r['code']} — {r['name']}"} for r in rows]
