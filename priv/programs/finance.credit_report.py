# ana:description Crédito e inadimplência: clientes com atraso, bloqueados e uso do limite
# ana:command credito
# ana:category Financeiro/Crédito e condições
"""RF-031-06. One set-based query over open receivables; actions on the row."""

from ana_lib.util.format import money

PARAMS = {"only_issues": {"type": "bool", "default": True, "label": "só quem tem atraso, bloqueio ou limite estourado"}}


def main(only_issues=True):
    pol = ana.sql_one("SELECT auto_block, grace_days FROM finance.credit_policy WHERE id = 1")
    rows = ana.sql(
        "WITH b AS (SELECT party_id, sum(amount) AS open_amount, "
        "                  sum(amount) FILTER (WHERE due_date < current_date) AS overdue, "
        "                  max(current_date - due_date) FILTER (WHERE due_date < current_date) AS max_days "
        "           FROM finance.bill WHERE kind = 'receivable' AND status = 'open' GROUP BY party_id), "
        "o AS (SELECT customer_id, sum(total) AS open_orders FROM sales.sales_order WHERE status = 'OPEN' GROUP BY customer_id), "
        "m AS (SELECT DISTINCT ON (party_id) party_id, reason FROM finance.credit_block WHERE released_at IS NULL "
        "      AND (until IS NULL OR until >= current_date) ORDER BY party_id, blocked_at DESC) "
        "SELECT p.id, p.name, COALESCE(b.open_amount, 0) AS open_amount, COALESCE(b.overdue, 0) AS overdue, b.max_days, "
        "  COALESCE(o.open_orders, 0) AS open_orders, cp.credit_limit, m.reason AS manual, "
        "  COALESCE(cp.auto_block, $1) AND COALESCE(b.max_days, 0) > COALESCE(cp.grace_days, $2) AS overdue_block "
        "FROM base.party p LEFT JOIN b ON b.party_id = p.id LEFT JOIN o ON o.customer_id = p.id "
        "LEFT JOIN finance.credit_profile cp ON cp.party_id = p.id LEFT JOIN m ON m.party_id = p.id "
        "WHERE p.kind IN ('customer', 'both') AND (NOT $3 OR b.overdue > 0 OR m.reason IS NOT NULL "
        "  OR (cp.credit_limit IS NOT NULL AND COALESCE(b.open_amount, 0) + COALESCE(o.open_orders, 0) > cp.credit_limit)) "
        "ORDER BY COALESCE(b.overdue, 0) DESC, p.name LIMIT 500", pol["auto_block"], pol["grace_days"], only_issues)
    blocked = [r for r in rows if r["manual"] or r["overdue_block"] or
               (r["credit_limit"] is not None and r["open_amount"] + r["open_orders"] > r["credit_limit"])]
    ana.metrics([{"label": "Clientes com atraso", "value": sum(1 for r in rows if r["overdue"] > 0),
                  "status": "warn" if any(r["overdue"] > 0 for r in rows) else "ok"},
                 {"label": "Bloqueados", "value": len(blocked), "status": "bad" if blocked else "ok"},
                 {"label": "Total em atraso", "value": money(sum((r["overdue"] for r in rows), 0))},
                 {"label": "Bloqueio automático", "value": f"ligado ({pol['grace_days']} dias)" if pol["auto_block"] else "desligado"}])

    def situation(r):
        if r["manual"]:
            return f"bloqueado: {r['manual']}"
        if r["overdue_block"]:
            return "bloqueado: inadimplência"
        if r["credit_limit"] is not None and r["open_amount"] + r["open_orders"] > r["credit_limit"]:
            return "bloqueado: limite"
        return "em atraso" if r["overdue"] > 0 else "ok"
    ana.table([{"cliente": f"{r['id']} — {r['name']}", "em aberto": r["open_amount"], "em atraso": r["overdue"],
                "maior atraso (dias)": r["max_days"], "pedidos em aberto": r["open_orders"], "limite": r["credit_limit"],
                "situação": situation(r),
                "_actions": ([{"label": "Desbloquear", "program": "finance.credit_block",
                               "params": {"customer": r["id"], "action": "unblock"},
                               "ask": {"reason": {"type": "str", "label": "motivo", "required": True}}}] if r["manual"] else
                             [{"label": "Bloquear", "program": "finance.credit_block", "params": {"customer": r["id"], "action": "block"},
                               "ask": {"reason": {"type": "str", "label": "motivo", "required": True}}}]) +
                            [{"label": "Liberar um pedido", "program": "finance.credit_block",
                              "params": {"customer": r["id"], "action": "release_order"},
                              "ask": {"reason": {"type": "str", "label": "justificativa", "required": True}}}]}
               for r in rows], title="Crédito por cliente")
    return {"customers": len(rows), "blocked": [r["id"] for r in blocked]}
