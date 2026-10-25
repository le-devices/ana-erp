# ana:description Grava as alterações da grade da previsão (só o que mudou, com controle de edição concorrente)
# ana:menu no
# ana:category Produção/Planejamento
"""Spec 020 (RF-020-15). changes: [{"key": {"product"}, "values": {"AAAA-MM-DD": quantidade|null}}]; version as read
by production.forecast_plan. Empty = no forecast for that week; negative quantities are refused."""

import datetime
from decimal import Decimal, InvalidOperation

from ana_lib.production import common

PARAMS = {
    "changes": {"type": "list", "required": True, "label": "alterações"},
    "version": {"type": "str", "label": "versão lida"},
    "start": {"type": "date", "required": True, "label": "primeira semana"},
    "weeks": {"type": "int", "required": True, "label": "semanas"},
    "product": {"type": "str", "label": "item (prefixo)"},
}


def main(changes, start, weeks, version=None, product=None):
    first = common.monday(start)
    last = first + datetime.timedelta(weeks=int(weeks))
    prefix = (product or "").strip().upper() or None
    ana.sql("SELECT pg_advisory_xact_lock(hashtext('production.forecast_plan'))")
    current = version_of(first, last, prefix)
    if version and current != version:
        raise ana.Error("CONFLICT", "a previsão foi alterada por outra pessoa depois que você abriu a grade: recarregue e refaça")
    items = common.products([(c.get("key") or {}).get("product") for c in changes]) if changes else {}
    upsert, remove = [], []
    for ch in changes:
        code = str((ch.get("key") or {}).get("product") or "").strip().upper()
        if prefix and not code.startswith(prefix):
            raise ana.Error("INVALID_PARAMETER", f"item {code} fora do escopo da grade")
        pid = items[code]["id"]
        for week, v in (ch.get("values") or {}).items():
            d = datetime.date.fromisoformat(str(week)[:10])
            if d != common.monday(d) or not first <= d < last:
                raise ana.Error("INVALID_PARAMETER", f"semana fora da grade: {week}")
            if v is None or str(v).strip() == "":
                remove.append([pid, d])
                continue
            try:
                q = Decimal(str(v))
            except InvalidOperation:
                raise ana.Error("INVALID_PARAMETER", f"{code} · {week}: quantidade inválida ({v})") from None
            if q < 0:
                raise ana.Error("INVALID_PARAMETER", f"{code} · {week}: previsão não pode ser negativa")
            upsert.append([pid, d, q])
    if upsert:
        ana.sql_batch("INSERT INTO production.forecast (product_id, week, quantity) VALUES ($1, $2, $3) "
                      "ON CONFLICT (product_id, week) DO UPDATE SET quantity = EXCLUDED.quantity", upsert)
    if remove:
        ana.sql_batch("DELETE FROM production.forecast WHERE product_id = $1 AND week = $2", remove)
    return {"saved": len(upsert), "removed": len(remove), "version": version_of(first, last, prefix)}


def version_of(first, last, prefix):
    """Same token as production.forecast_plan.version."""
    return ana.sql_value("SELECT md5(COALESCE(string_agg(concat_ws(';', p.code, f.week, f.quantity), '|' ORDER BY p.code, f.week), '')) "
                         "FROM production.forecast f JOIN base.product p ON p.id = f.product_id "
                         "WHERE f.week >= $1 AND f.week < $2 AND ($3::text IS NULL OR p.code LIKE $3 || '%')", first, last, prefix)
