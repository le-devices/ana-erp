# ana:description Fatura ordens de serviço concluídas (horas, deslocamento e peças) ou lança no projeto
# ana:exposed yes
"""RF-015-09, CA-015-04. Standalone order: lines hours (work hours × the technician profile's
rate), travel (hours × travel rate + km × km rate, logistics.policy) and parts (× price); bill
and entry (D customers / C service_revenue and sales_revenue), document OS-n. Order of a
project: work hours become approved time entries on the activity and parts/travel become
rebillable project expenses (the project invoices them)."""

import datetime
from decimal import Decimal, ROUND_HALF_UP

from ana_lib.logistics import common as lc
from ana_lib.docs.common import link as doc_link

PARAMS = {
    "orders": {"type": "list", "label": "OS (vazio = todas as concluídas)"},
    "payment_days": {"type": "int", "default": 30, "label": "prazo de pagamento (dias)"},
}
CENT = Decimal("0.01")


def money(v):
    return Decimal(v).quantize(CENT, ROUND_HALF_UP)


def main(orders=None, payment_days=30):
    rows = ana.sql("SELECT o.id, o.number, o.customer_id, o.project_id, o.task_id, p.cost_center FROM field.service_order o "
                   "LEFT JOIN projects.project p ON p.id = o.project_id WHERE o.status = 'done' "
                   "AND ($1::bigint[] IS NULL OR o.number = ANY($1)) ORDER BY o.number FOR UPDATE OF o",
                   [int(n) for n in orders] if orders else None)
    if not rows:
        raise ana.Error("NOTHING_TO_INVOICE", "nenhuma OS concluída para faturar")
    ids = [r["id"] for r in rows]
    pol = lc.policy()
    work = ana.sql("SELECT w.order_id, w.employee_id, e.name, e.profile, e.hourly_cost, rp.hourly_rate, w.kind, sum(w.hours) AS hours, "
                   "  sum(w.km) AS km, min(w.logged_at)::date AS day FROM field.work_log w JOIN projects.employee e ON e.id = w.employee_id "
                   "JOIN projects.rate_profile rp ON rp.code = e.profile WHERE w.order_id = ANY($1) "
                   "GROUP BY 1, 2, 3, 4, 5, 6, 7", ids)
    parts = ana.sql("SELECT u.order_id, u.product_id, p.code, p.description, sum(u.quantity) AS q, u.unit_price FROM field.part_usage u "
                    "JOIN base.product p ON p.id = u.product_id WHERE u.order_id = ANY($1) GROUP BY 1, 2, 3, 4, 6", ids)
    out = []
    for r in rows:
        w = [x for x in work if x["order_id"] == r["id"]]
        pts = [x for x in parts if x["order_id"] == r["id"]]
        lines = []
        for x in [x for x in w if x["kind"] == "work"]:
            lines.append(("hours", f"Horas de {x['name']} ({x['profile']})", x["hours"], x["hourly_rate"]))
        th = sum((x["hours"] for x in w if x["kind"] == "travel"), Decimal(0))
        km = sum((x["km"] for x in w), Decimal(0))
        if th and pol["travel_hour_rate"]:
            lines.append(("travel", "Deslocamento (horas)", th, pol["travel_hour_rate"]))
        if km and pol["travel_km_rate"]:
            lines.append(("travel", "Deslocamento (km)", km, pol["travel_km_rate"]))
        for x in pts:
            lines.append(("parts", f"{x['code']} — {x['description']}", x["q"], x["unit_price"]))
        lines = [(k, d, Decimal(q), Decimal(p), money(Decimal(q) * Decimal(p))) for k, d, q, p in lines]
        doc = f"OS-{r['number']}"
        if r["project_id"]:
            entries = [x for x in w if x["kind"] == "work"]
            if entries:
                # ana:lint-ok sql_in_loop — one batch per order (a handful of technicians each)
                ana.sql_batch("INSERT INTO projects.time_entry (project_id, task_id, employee_id, entry_date, hours, description, "
                              "  status, profile, hourly_rate, hourly_cost, approved_by, approved_at, created_by) "
                              "VALUES ($1, $2, $3, $4, $5, $6, 'approved', $7, $8, $9, $10, now(), $10)",
                              [[r["project_id"], r["task_id"], x["employee_id"], x["day"], (x["hours"] * 4).to_integral_value() / 4,
                                f"Atendimento em campo {doc}", x["profile"], x["hourly_rate"], x["hourly_cost"], ana.context.user]
                               for x in entries])
            expenses = [l for l in lines if l[0] != "hours"]
            if expenses:
                # ana:lint-ok sql_in_loop — one batch per order
                ana.sql_batch("INSERT INTO projects.expense (project_id, kind, description, quantity, unit_cost, rebillable, created_by) "
                              "VALUES ($1, $2, $3, $4, $5, true, $6)",
                              [[r["project_id"], "travel" if l[0] == "travel" else "component", f"{l[1]} ({doc})", l[2], l[3],
                                ana.context.user] for l in expenses])
            entry = bill = None
        else:
            services = sum((l[4] for l in lines if l[0] != "parts"), Decimal(0))
            goods = sum((l[4] for l in lines if l[0] == "parts"), Decimal(0))
            total = services + goods
            if total <= 0:
                raise ana.Error("NOTHING_TO_INVOICE", f"OS {r['number']} sem valores a faturar")
            # ana:lint-ok sql_in_loop — one entry and one bill per order (each is its own document)
            entry = ana.sql_value("INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
                                  f"Ordem de serviço {r['number']}", doc, ana.context.user)
            ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit) VALUES ($1, finance.account_for($2), $3, $4)",
                          [l for l in [[entry, "customers", total, 0], [entry, "service_revenue", 0, services],
                                       [entry, "sales_revenue", 0, goods]] if l[2] or l[3]])
            # ana:lint-ok sql_in_loop — one bill per order
            bill = ana.sql_value("INSERT INTO finance.bill (kind, party_id, document, due_date, amount, entry_id) "
                                 "VALUES ('receivable', $1, $2, $3, $4, $5) RETURNING id", r["customer_id"], doc,
                                 datetime.date.today() + datetime.timedelta(days=payment_days), total, entry)
        if lines:
            # ana:lint-ok sql_in_loop — one batch per order
            ana.sql_batch("INSERT INTO field.invoice_line (order_id, line, kind, description, quantity, unit_price, amount) "
                          "VALUES ($1, $2, $3, $4, $5, $6, $7)", [[r["id"], n, *l] for n, l in enumerate(lines, start=1)])
        out.append({"order": r["number"], "project": bool(r["project_id"]), "lines": len(lines),
                    "total": sum((l[4] for l in lines), Decimal(0)), "bill": bill, "entry": entry})
    ana.sql_exec("UPDATE field.service_order o SET status = 'invoiced', invoiced_at = now(), entry_id = x.e, bill_id = x.b "
                 "FROM unnest($1::int[], $2::bigint[], $3::bigint[]) AS x(id, e, b) WHERE o.id = x.id",
                 ids, [o["entry"] for o in out], [o["bill"] for o in out])
    ana.table([{"OS": o["order"], "_open": doc_link("service_order", o["order"]), "destino": "projeto" if o["project"] else "fatura", "linhas": o["lines"], "total": o["total"]}
               for o in out], title="Ordens faturadas")
    return {"orders": out}
