# ana:description Regra de rateio de custos entre centros
# ana:exposed yes
# ana:role admin
"""RF-027-06. targets: [{"cost_center": "ENG", "pct": 60}, {"cost_center": "COM", "pct": 40}] (sum = 100)."""

from decimal import Decimal

PARAMS = {
    "code": {"type": "str", "required": True, "label": "código"},
    "name": {"type": "str", "required": True, "label": "nome"},
    "source": {"type": "str", "required": True, "label": "centro de origem",
               "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}},
    "targets": {"type": "list", "required": True, "label": "destinos com percentuais"},
    "account_prefix": {"type": "str", "default": "5", "label": "contas que começam com"},
    "active": {"type": "bool", "default": True, "label": "ativa"},
}


def main(code, name, source, targets, account_prefix="5", active=True):
    source = source.upper()
    total = sum(Decimal(str(t.get("pct", 0))) for t in targets)
    if total != 100:
        raise ana.Error("INVALID_TARGETS", f"os percentuais somam {total}%; devem somar 100%")
    clean = [{"cost_center": str(t["cost_center"]).upper(), "pct": str(Decimal(str(t["pct"])))} for t in targets]
    if any(t["cost_center"] == source for t in clean):
        raise ana.Error("INVALID_TARGETS", "o centro de origem não pode ser destino")
    usable = {r["code"] for r in ana.sql("SELECT code FROM finance.cost_center WHERE code = ANY($1) AND active",
                                         [t["cost_center"] for t in clean])}
    missing = [t["cost_center"] for t in clean if t["cost_center"] not in usable]
    if missing:
        raise ana.Error("COST_CENTER_INACTIVE", "centros inexistentes ou inativos: " + ", ".join(missing))
    ana.sql_exec("INSERT INTO finance.allocation_rule (code, name, source, account_prefix, targets, active) "
                 "VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, "
                 "source = EXCLUDED.source, account_prefix = EXCLUDED.account_prefix, targets = EXCLUDED.targets, "
                 "active = EXCLUDED.active", code.upper(), name, source, account_prefix, clean, active)
    return {"code": code.upper(), "targets": clean}
