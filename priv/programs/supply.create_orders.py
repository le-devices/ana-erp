# ana:description Gera ordens de compra das solicitações aprovadas, por fornecedor
# ana:exposed yes
# ana:command ordens
# ana:category Compras/Ordens de compra
"""RF-013-04. Approved request lines are grouped by supplier (the line's or the item's
preferred one) and delivery warehouse; price and promised date come from the catalog."""

import datetime
from decimal import Decimal, ROUND_HALF_UP
from ana_lib.docs.common import link as doc_link
from ana_lib.docs import pdfs

PARAMS = {
    "requests": {"type": "list", "label": "solicitações (vazio = todas as aprovadas)"},
    "send": {"type": "bool", "default": True, "label": "enviar as ordens ao fornecedor"},
    "notes": {"type": "str", "label": "observações"},
}


def main(requests=None, send=True, notes=None):
    reqs = ana.sql("SELECT id, number FROM supply.purchase_request WHERE status = 'approved' "
                   "AND ($1::bigint[] IS NULL OR number = ANY($1)) ORDER BY number FOR UPDATE",
                   [int(n) for n in requests] if requests else None)
    if requests and len(reqs) != len(set(int(n) for n in requests)):
        found = {r["number"] for r in reqs}
        raise ana.Error("INVALID_STATE", "não aprovadas ou inexistentes: " +
                        ", ".join(str(n) for n in sorted(set(int(n) for n in requests) - found)))
    if not reqs:
        raise ana.Error("NOTHING_TO_ORDER", "nenhuma solicitação aprovada para comprar")
    lines = ana.sql(
        "SELECT r.id AS request_id, r.number, r.warehouse_id, r.project_id, r.cost_center, r.need_date, "
        "  l.line, l.product_id, pr.code, l.quantity, l.est_price, l.rebillable, "
        "  COALESCE(l.supplier_id, pref.supplier_id) AS supplier_id, si.price AS catalog_price, si.currency, si.lead_time_days "
        "FROM supply.purchase_request r JOIN supply.purchase_request_line l ON l.request_id = r.id "
        "JOIN base.product pr ON pr.id = l.product_id "
        "LEFT JOIN supply.supplier_item pref ON pref.product_id = l.product_id AND pref.preferred "
        "LEFT JOIN supply.supplier_item si ON si.product_id = l.product_id "
        "  AND si.supplier_id = COALESCE(l.supplier_id, pref.supplier_id) "
        "WHERE r.id = ANY($1) ORDER BY r.number, l.line", [r["id"] for r in reqs])
    orphan = sorted({f"{l['number']}/{l['code']}" for l in lines if l["supplier_id"] is None})
    if orphan:
        raise ana.Error("NO_SUPPLIER", "sem fornecedor (defina um preferencial no catálogo): " + ", ".join(orphan))

    # Spec 069 (T-069-01): an order keeps the currency of its prices — the catalog's (dollar, euro…), else the
    # request's estimate in reais; one order per supplier, warehouse and currency.
    groups = {}
    for l in lines:
        cur = (l["currency"] or "BRL") if l["catalog_price"] is not None else "BRL"
        groups.setdefault((l["supplier_id"], l["warehouse_id"], cur), []).append(l)
    keys = sorted(groups)
    suppliers = {r["id"]: r["name"] for r in ana.sql(
        "SELECT id, name FROM base.party WHERE id = ANY($1) AND active AND kind IN ('supplier', 'both')",
        sorted({k[0] for k in keys}))}
    inactive = sorted({str(k[0]) for k in keys if k[0] not in suppliers})
    if inactive:
        raise ana.Error("SUPPLIER_NOT_FOUND", "fornecedor(es) inativo(s) ou inexistente(s): " + ", ".join(inactive))
    payment_days = ana.sql_value("SELECT default_payment_days FROM supply.policy WHERE id = 1") or 30
    today = datetime.date.today()
    rows = {}
    for key in keys:
        batch = []
        for n, l in enumerate(groups[key], start=1):
            price = l["catalog_price"] if l["catalog_price"] is not None else l["est_price"]
            promised = today + datetime.timedelta(days=l["lead_time_days"]) if l["lead_time_days"] is not None else l["need_date"]
            batch.append([n, l["product_id"], l["quantity"], price, promised, l["request_id"], l["line"],
                          l["project_id"], l["cost_center"], l["rebillable"]])
        rows[key] = batch
    totals = [sum((b[2] * b[3] for b in rows[k]), Decimal(0)).quantize(Decimal("0.01"), ROUND_HALF_UP) for k in keys]
    # All orders in one statement, then all lines in one batch (no round trip per supplier).
    orders = ana.sql(
        "INSERT INTO supply.purchase_order (supplier_id, warehouse_id, payment_days, notes, created_by, total, status, sent_at, "
        "  currency) "
        "SELECT s, w, $3, $4, $5, t::numeric, CASE WHEN $6 THEN 'sent' ELSE 'draft' END, CASE WHEN $6 THEN now() END, c "
        "FROM unnest($1::int[], $2::int[], $7::text[], $8::text[]) WITH ORDINALITY AS x(s, w, t, c, n) ORDER BY n "
        "RETURNING id, number, supplier_id, warehouse_id, currency",
        [k[0] for k in keys], [k[1] for k in keys], payment_days, notes, ana.context.user, send, [str(t) for t in totals],
        [k[2] for k in keys])
    ids = {(o["supplier_id"], o["warehouse_id"], o["currency"]): o for o in orders}
    ana.sql_batch("INSERT INTO supply.purchase_order_line (order_id, line, product_id, quantity, price, promised_date, "
                  "  request_id, request_line, project_id, cost_center, rebillable) "
                  "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)",
                  [[ids[k]["id"], *b] for k in keys for b in rows[k]])
    created = [{"ordem": ids[k]["number"], "_open": doc_link("purchase_order", ids[k]["number"]), "fornecedor": suppliers[k[0]], "linhas": len(rows[k]), "total": t, "moeda": k[2],
                "situação": "enviada" if send else "rascunho",
                "_actions": [{"label": "Receber", "program": "supply.receive", "params": {"order": ids[k]["number"]},
                              "confirm": f"Receber tudo o que está pendente na ordem {ids[k]['number']}?"}] if send else []}
               for k, t in zip(keys, totals)]
    ana.sql_exec("UPDATE supply.purchase_request SET status = 'ordered' WHERE id = ANY($1)", [r["id"] for r in reqs])
    if send:
        for c in created:
            # ana:lint-ok sql_in_loop — one PDF per purchase order sent to its supplier
            pdfs.publish_quietly("purchase_order", c["ordem"])
    ana.table(created, title="Ordens de compra geradas")
    return {"orders": [c["ordem"] for c in created], "requests": [r["number"] for r in reqs]}
