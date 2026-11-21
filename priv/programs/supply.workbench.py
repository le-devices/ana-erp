# ana:description Bancada de compras: aprovar, comprar, receber e acompanhar prazos
# ana:command compras
# ana:category Compras/Ordens de compra
"""Purchasing workbench (H2–H4): each view lists what waits for a decision, with the
action on the row itself."""

import datetime

from ana_lib.supply import common
from ana_lib.docs.common import link as doc_link

PARAMS = {
    "view": {"type": "str", "default": "approve", "label": "visão",
             "choices": [["approve", "A aprovar"], ["buy", "A comprar"], ["receive", "A receber"], ["late", "Atrasadas"]]},
}
VIEWS = [("approve", "A aprovar"), ("buy", "A comprar"), ("receive", "A receber"), ("late", "Atrasadas")]
WB = "supply.workbench"


def main(view="approve"):
    today = datetime.date.today()
    c = ana.sql_one(
        "SELECT (SELECT count(*) FROM supply.purchase_request WHERE status = 'submitted') AS to_approve, "
        "  (SELECT count(*) FROM supply.purchase_request WHERE status = 'approved') AS to_buy, "
        "  (SELECT count(*) FROM supply.purchase_order WHERE status IN ('sent', 'partially_received')) AS to_receive, "
        "  (SELECT count(DISTINCT o.id) FROM supply.purchase_order o JOIN supply.purchase_order_line l ON l.order_id = o.id "
        "   WHERE o.status IN ('sent', 'partially_received') AND l.received_qty < l.quantity AND l.promised_date < $1) AS late, "
        "  (SELECT COALESCE(sum(l.quantity * l.price - LEAST(l.received_qty, l.quantity) * l.price), 0) "
        "   FROM supply.purchase_order o JOIN supply.purchase_order_line l ON l.order_id = o.id "
        "   WHERE o.status IN ('sent', 'partially_received')) AS open_amount", today)
    ana.metrics([{"label": "A aprovar", "value": c["to_approve"], "status": "warn" if c["to_approve"] else "ok"},
                 {"label": "A comprar", "value": c["to_buy"], "status": "warn" if c["to_buy"] else "ok"},
                 {"label": "Ordens a receber", "value": c["to_receive"]},
                 {"label": "Ordens atrasadas", "value": c["late"], "status": "bad" if c["late"] else "ok"},
                 {"label": "Em aberto com fornecedores", "value": f"R$ {c['open_amount']:.2f}"}])
    ana.tabs([{"label": label, "program": WB, "params": {"view": v}, "open": True} for v, label in VIEWS], current=view)

    if view == "approve":
        limit = common.approval_limit()
        rows = ana.sql(
            "SELECT r.number, r.requester, r.reason, r.need_date, r.total, pj.code AS project, w.code AS warehouse, "
            "  string_agg(pr.code || ' × ' || l.quantity::text, ', ' ORDER BY l.line) AS items "
            "FROM supply.purchase_request r JOIN supply.purchase_request_line l ON l.request_id = r.id "
            "JOIN base.product pr ON pr.id = l.product_id JOIN inventory.warehouse w ON w.id = r.warehouse_id "
            "LEFT JOIN projects.project pj ON pj.id = r.project_id WHERE r.status = 'submitted' "
            "GROUP BY r.id, pj.code, w.code ORDER BY r.need_date NULLS LAST, r.number LIMIT 200")
        ana.table([{"solicitação": r["number"], "_open": doc_link("purchase_request", r["number"]), "solicitante": r["requester"], "itens": r["items"], "motivo": r["reason"],
                    "necessária em": r["need_date"], "projeto": r["project"], "total": r["total"],
                    "_actions": [] if r["requester"] == ana.context.user or (limit is not None and r["total"] > limit) else [
                        {"label": "Aprovar", "program": "supply.approve_request", "params": {"request": r["number"]}, "style": "primary"},
                        {"label": "Recusar", "program": "supply.approve_request",
                         "params": {"request": r["number"], "decision": "reject"},
                         "ask": {"reason": {"type": "str", "label": "motivo", "required": True}}}]}
                   for r in rows], title="Solicitações aguardando aprovação")
    elif view == "buy":
        rows = ana.sql(
            "SELECT r.number, r.requester, r.need_date, r.total, r.approved_by, "
            "  string_agg(pr.code || ' × ' || l.quantity::text || ' — ' || COALESCE(pa.name, 'sem fornecedor'), ', ' "
            "             ORDER BY l.line) AS items "
            "FROM supply.purchase_request r JOIN supply.purchase_request_line l ON l.request_id = r.id "
            "JOIN base.product pr ON pr.id = l.product_id "
            "LEFT JOIN supply.supplier_item si ON si.product_id = l.product_id AND si.preferred "
            "LEFT JOIN base.party pa ON pa.id = COALESCE(l.supplier_id, si.supplier_id) "
            "WHERE r.status = 'approved' GROUP BY r.id ORDER BY r.need_date NULLS LAST, r.number LIMIT 200")
        ana.table([{"solicitação": r["number"], "_open": doc_link("purchase_request", r["number"]), "solicitante": r["requester"], "itens e fornecedores": r["items"],
                    "necessária em": r["need_date"], "aprovada por": r["approved_by"], "total": r["total"],
                    "_actions": [{"label": "Gerar ordem", "program": "supply.create_orders", "params": {"requests": [r["number"]]}}]}
                   for r in rows], title="Aprovadas, aguardando compra")
        if rows:
            ana.actions([{"label": "Gerar ordens de todas", "program": "supply.create_orders", "style": "primary",
                          "confirm": f"Gerar ordens para {len(rows)} solicitação(ões)?"}])
    else:
        rows = ana.sql(
            "SELECT o.number, pa.name, o.status, o.total, min(l.promised_date) FILTER (WHERE l.received_qty < l.quantity) AS next_date, "
            "  string_agg(pr.code || ' ' || l.received_qty::text || '/' || l.quantity::text, ', ' ORDER BY l.line) AS items "
            "FROM supply.purchase_order o JOIN base.party pa ON pa.id = o.supplier_id "
            "JOIN supply.purchase_order_line l ON l.order_id = o.id JOIN base.product pr ON pr.id = l.product_id "
            "WHERE o.status IN ('sent', 'partially_received') GROUP BY o.id, pa.name "
            "HAVING $1 = false OR min(l.promised_date) FILTER (WHERE l.received_qty < l.quantity) < $2 "
            "ORDER BY next_date NULLS LAST, o.number LIMIT 200", view == "late", today)
        ana.table([{"ordem": r["number"], "_open": doc_link("purchase_order", r["number"]), "fornecedor": r["name"], "recebido/pedido": r["items"], "prometida para": r["next_date"],
                    "atraso (dias)": (today - r["next_date"]).days if r["next_date"] and r["next_date"] < today else None,
                    "situação": "recebida em parte" if r["status"] == "partially_received" else "enviada", "total": r["total"],
                    "_actions": [{"label": "Receber tudo", "program": "supply.receive", "params": {"order": r["number"]},
                                  "style": "primary", "confirm": f"Receber tudo o que está pendente na ordem {r['number']}?"},
                                 {"label": "Receber em parte", "program": "supply.receive",
                                  "params": {"order": r["number"], "_form": "1"}, "open": True},
                                 {"label": "Novo prazo", "program": "supply.confirm_delivery_date", "params": {"order": r["number"]},
                                  "ask": {"promised_date": {"type": "date", "label": "nova data", "required": True}}}]}
                   for r in rows], title="Ordens atrasadas" if view == "late" else "Ordens aguardando recebimento")
    ana.actions([{"label": "Nova solicitação", "program": "supply.request_purchase", "open": True},
                 {"label": "Sugestão de reposição", "program": "supply.suggest_replenishment", "open": True},
                 {"label": "Desempenho de fornecedores", "program": "supply.supplier_performance", "open": True}],
                title="Outras tarefas")
    return {"view": view, "counts": c}
