# ana:description Grava as alterações da grade do orçamento (só o que mudou, com controle de edição concorrente)
# ana:role admin
# ana:menu no
# ana:category Contabilidade/Custos e orçamento
"""Spec 020 (RF-020-15, CA-020-10). changes: [{"key": {"cost_center", "account"}, "values": {"AAAA-MM": valor|null},
"status"?, "comment"?}]; version: what the grid read (finance.budget_plan). Someone else saved the same scope in
between → CONFLICT (nothing saved). A null or empty value removes that month."""

from decimal import Decimal, InvalidOperation

from ana_lib.finance import budget

PARAMS = {
    "changes": {"type": "list", "required": True, "label": "alterações"},
    "version": {"type": "str", "label": "versão lida"},
    "start": {"type": "str", "required": True, "label": "de (mês)"},
    "end": {"type": "str", "required": True, "label": "até (mês)"},
    "cost_center": {"type": "str", "label": "centro de custo"},
    "account": {"type": "str", "label": "conta"},
}
MAX_CHANGES = 5000


def main(changes, start, end, version=None, cost_center=None, account=None):
    months = budget.months(start, end)
    scope = budget.scope(months, cost_center, account)
    ana.sql("SELECT pg_advisory_xact_lock(hashtext('finance.budget_plan'))")      # one save at a time: the check holds
    if version and budget.version(scope) != version:
        raise ana.Error("CONFLICT", "o orçamento foi alterado por outra pessoa depois que você abriu a grade: recarregue e refaça")
    if len(changes) > MAX_CHANGES:
        raise ana.Error("INVALID_PARAMETER", f"no máximo {MAX_CHANGES} linhas por gravação")
    allowed = {m.isoformat()[:7]: m for m in months}
    upsert, remove, lines, who = [], [], [], ana.context.user
    for ch in changes:
        k = ch.get("key") or {}
        cc, acc = str(k.get("cost_center") or "").upper(), str(k.get("account") or "")
        if not cc or not acc:
            raise ana.Error("INVALID_PARAMETER", "toda linha precisa de centro de custo e conta")
        budget.check_line(cc, acc, scope)
        for period, v in (ch.get("values") or {}).items():
            if period not in allowed:
                raise ana.Error("INVALID_PARAMETER", f"mês fora do intervalo da grade: {period}")
            if v is None or str(v).strip() == "":
                remove.append([cc, acc, allowed[period]])
                continue
            try:
                amount = Decimal(str(v))
            except InvalidOperation:
                raise ana.Error("INVALID_PARAMETER", f"{cc} · {acc} · {period}: valor inválido ({v})") from None
            if amount < 0:
                raise ana.Error("INVALID_PARAMETER", f"{cc} · {acc} · {period}: orçamento não pode ser negativo")
            upsert.append([cc, acc, allowed[period], amount])
        if "status" in ch or "comment" in ch:
            status = ch.get("status") or "draft"
            if status not in dict(budget.STATUSES):
                raise ana.Error("INVALID_PARAMETER", f"situação desconhecida: {status}")
            lines.append([cc, acc, status, str(ch.get("comment") or "")[:500], who])
    if upsert:
        ana.sql_batch("INSERT INTO finance.cost_center_budget (cost_center, account, month, amount) VALUES ($1, $2, $3, $4) "
                      "ON CONFLICT (cost_center, account, month) DO UPDATE SET amount = EXCLUDED.amount", upsert)
    if remove:
        ana.sql_batch("DELETE FROM finance.cost_center_budget WHERE cost_center = $1 AND account = $2 AND month = $3", remove)
    if lines:
        ana.sql_batch("INSERT INTO finance.cost_center_budget_line (cost_center, account, status, comment, updated_by) "
                      "VALUES ($1, $2, $3, $4, $5) ON CONFLICT (cost_center, account) DO UPDATE SET status = EXCLUDED.status, "
                      "comment = EXCLUDED.comment, updated_by = EXCLUDED.updated_by, updated_at = now()", lines)
    return {"saved": len(upsert), "removed": len(remove), "lines": len(lines), "version": budget.version(scope)}
