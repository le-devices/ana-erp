# ana:description Uso simulado: os oráculos do fim da rodada — esteiras paradas, contas que não fecham, filas esgotadas
# ana:menu no
"""Spec 067 (D4, RF-067-04). Read-only checks over what the run did (since it started): each answer is a finding with a
stable key (the same furo in the next run is the same finding — persistent — not a new one)."""

from decimal import Decimal

PARAMS = {"since": {"type": "str", "required": True, "label": "início da rodada (ISO)"},
          "reconciliations": {"type": "dict", "label": "conciliações no início"},
          "last_entry": {"type": "int", "label": "último lançamento antes da rodada"}}
CENT = Decimal("0.01")


def finding(category, severity, key, title, **detail):
    return {"category": category, "severity": severity, "key": key, "title": title, "detail": detail}


def main(since, reconciliations=None, last_entry=0):
    out = []
    # Accounts (spec 042): each control reconciliation must be where it was — the run's documents all settle.
    before = {k: Decimal(str(v or 0)) for k, v in (reconciliations or {}).items()}
    now = {r["key"]: Decimal(str(r["difference"] or 0)) for r in ana.sql("SELECT key, difference FROM finance.reconciliation()")}
    for k, v in now.items():
        moved = (v - before.get(k, Decimal(0))).quantize(CENT)
        if abs(moved) >= CENT:
            out.append(finding("accounts", "serious", f"reconciliation:{k}",
                               f"Conciliação {k} mudou {moved} durante o uso simulado", reconciliation=k, moved=str(moved)))
    for r in ana.sql("SELECT e.id, e.memo, round(sum(l.debit) - sum(l.credit), 2) AS diff FROM finance.journal_entry e "
                     "JOIN finance.journal_line l ON l.entry_id = e.id WHERE e.id > $1 GROUP BY e.id, e.memo "
                     "HAVING round(sum(l.debit) - sum(l.credit), 2) <> 0 ORDER BY e.id LIMIT 20", last_entry or 0):
        out.append(finding("accounts", "critical", f"unbalanced:{(r['memo'] or '')[:40]}",
                           f"Lançamento desbalanceado: {r['memo']}", entry=r["id"], difference=str(r["diff"])))
    for r in ana.sql("SELECT p.code, w.code AS warehouse, sum(m.quantity) AS q FROM inventory.stock_movement m "
                     "JOIN base.product p ON p.id = m.product_id JOIN inventory.warehouse w ON w.id = m.warehouse_id "
                     "WHERE p.id IN (SELECT product_id FROM inventory.stock_movement WHERE created_at >= $1::timestamptz) "
                     "GROUP BY p.code, w.code HAVING sum(m.quantity) < 0 LIMIT 20", since):
        out.append(finding("accounts", "serious", f"negative_stock:{r['warehouse']}",
                           f"Saldo negativo de {r['code']} no depósito {r['warehouse']}", product=r["code"], quantity=str(r["q"])))
    # Automation: pipeline steps that failed or stood still, messages to connectors given up, scheduled routines in error.
    for r in ana.sql("SELECT i.flow_code, s.code, i.doc_key, x.status, x.error->>'message' AS message "
                     "FROM flow.instance_step x JOIN flow.instance i ON i.id = x.instance_id "
                     "JOIN flow.step s ON s.flow_code = i.flow_code AND s.seq = x.seq "
                     "WHERE (x.status = 'failed' OR (x.status IN ('pending', 'ready') AND s.mode = 'auto' "
                     "       AND COALESCE(x.next_at, i.updated_at) < now() - interval '5 minutes')) "
                     "AND i.updated_at >= $1::timestamptz - interval '1 day' ORDER BY i.id LIMIT 50", since):
        stopped = r["status"] == "failed"
        out.append(finding("automation", "serious", f"flow:{r['flow_code']}:{r['code']}:{r['status']}",
                           f"Esteira {r['flow_code']} parada na etapa {r['code']}"
                           + (f": {r['message']}" if stopped and r["message"] else " (etapa automática não andou)"),
                           flow=r["flow_code"], step=r["code"], document=r["doc_key"], status=r["status"], error=r["message"]))
    # Queues of connectors and scheduled routines are read by the core (simulation.erl): programs do not see them.
    return {"findings": out}
