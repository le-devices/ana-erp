# ana:description Roteiro do item: operações em sequência com recurso, preparação e tempo por unidade
# ana:exposed yes
"""RF-014-02. Each save creates a new active version."""

from ana_lib.production import common

PARAMS = {
    "product": {"type": "str", "required": True, "label": "item", "lookup": {"program": "production.lookup", "params": {"kind": "made"}}},
    "operations": {"type": "list", "required": True, "label": "operações",
                   "help": '[{"resource": "SMD", "description": "montagem", "setup_min": 30, "run_min": 6}]'},
}


def main(product, operations):
    p = common.product(product)
    if not 0 < len(operations) <= 200:
        raise ana.Error("INVALID_OPERATIONS", "o roteiro deve ter de 1 a 200 operações")
    codes = sorted({str(o.get("resource", "")).upper() for o in operations})
    known = {r["code"] for r in ana.sql("SELECT code FROM production.resource WHERE code = ANY($1) AND active", codes)}
    missing = [c for c in codes if c not in known]
    if missing:
        raise ana.Error("RESOURCE_NOT_FOUND", "recursos inexistentes: " + ", ".join(missing))
    version = ana.sql_value("SELECT COALESCE(max(version), 0) + 1 FROM production.routing WHERE product_id = $1", p["id"])
    ana.sql_exec("UPDATE production.routing SET active = false WHERE product_id = $1 AND active", p["id"])
    rid = ana.sql_value("INSERT INTO production.routing (product_id, version, created_by) VALUES ($1, $2, $3) RETURNING id",
                        p["id"], version, ana.context.user)
    ana.sql_batch("INSERT INTO production.operation (routing_id, seq, resource_code, description, setup_min, run_min) "
                  "VALUES ($1, $2, $3, $4, $5, $6)",
                  [[rid, (o.get("seq") or n * 10), str(o["resource"]).upper(), o.get("description") or f"operação {n}",
                    o.get("setup_min") or 0, o.get("run_min") or 0] for n, o in enumerate(operations, start=1)])
    return {"product": p["code"], "version": version, "operations": len(operations)}
