# ana:description Regras comuns de compras (fornecedor, depósito, centro de custo, alçada)
# ana:kind library
"""Shared lookups for the supply programs (spec 013)."""

import ana


def supplier(supplier_id):
    s = ana.sql_one("SELECT id, name FROM base.party WHERE id = $1 AND active AND kind IN ('supplier', 'both')",
                    supplier_id)
    if not s:
        raise ana.Error("SUPPLIER_NOT_FOUND", f"fornecedor {supplier_id} não encontrado")
    return s


def warehouse(code):
    w = ana.sql_one("SELECT id, code, cost_center FROM inventory.warehouse WHERE code = $1", str(code).upper())
    if not w:
        raise ana.Error("WAREHOUSE_NOT_FOUND", f"depósito {code} não encontrado")
    return w


def project(code):
    if not code:
        return None
    p = ana.sql_one("SELECT id, code, status, cost_center FROM projects.project WHERE code = $1", str(code).upper())
    if not p:
        raise ana.Error("PROJECT_NOT_FOUND", f"projeto {code} não encontrado")
    if p["status"] == "closed":
        raise ana.Error("PROJECT_INACTIVE", f"projeto {p['code']} está encerrado")
    return p


def products(codes):
    codes = sorted({str(c).upper() for c in codes})
    found = {r["code"]: r for r in ana.sql(
        "SELECT id, code, description, kind FROM base.product WHERE code = ANY($1) AND active", codes)}
    missing = [c for c in codes if c not in found]
    if missing:
        raise ana.Error("PRODUCT_NOT_FOUND", "itens inexistentes: " + ", ".join(missing))
    return found


def approval_limit():
    """Largest amount the current user may approve; None = unlimited."""
    return ana.sql_value("SELECT supply.approval_limit_of($1, $2) AS v", ana.context.user, ana.context.role)


def is_admin():
    return ana.context.role == "admin"
