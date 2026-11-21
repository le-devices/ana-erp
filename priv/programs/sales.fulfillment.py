# ana:description Política de atendimento do pedido de venda: regra efetiva, suprimento vinculado, liberação e cancelamento
# ana:kind library
"""Spec 041. Used by sales.create_order (every path — screen, public API, portal, flows, BPM — creates orders
through it), sales.cancel_order, sales.release_held and the policy screen.

Modes when stock is missing (D2): refuse, hold, purchase, produce, by_item (the item's planning: make or buy),
accept. The most specific rule wins (D1): customer + item > item > item group > customer > policy."""

import datetime
from decimal import Decimal, ROUND_CEILING

import ana

MODES = [["refuse", "Só com estoque — recusar"], ["hold", "Só com estoque — reter até chegar"],
         ["purchase", "Suprir pela compra"], ["produce", "Suprir pela produção"],
         ["by_item", "Suprir conforme o item (fabricado ou comprado)"], ["accept", "Aceitar sem estoque definido"]]
LABEL = dict(MODES)
STRICT = {"refuse", "hold"}          # always allowed to whoever types: stricter than any policy
STATUS = {"ok": "pode expedir", "held": "retido: aguardando estoque", "supply": "aguardando compra ou produção",
          "short": "aceito com falta: alguém decide"}
ZERO = Decimal(0)


def policy():
    return ana.sql_one("SELECT mode, transfer_first, auto_order_max, allowed_modes, confirm_cancel FROM sales.fulfillment_policy WHERE id = 1")


def effective(customer_id, products):
    """{product_id: {"mode", "transfer_first", "source"}} for the customer's lines (products: [{id, code, item_group}])."""
    pol = policy()
    ids = [p["id"] for p in products]
    groups = sorted({p.get("item_group") for p in products if p.get("item_group")})
    rules = ana.sql("SELECT customer_id, product_id, item_group, mode, transfer_first FROM sales.fulfillment_rule "
                    "WHERE (customer_id IS NULL OR customer_id = $1) AND (product_id IS NULL OR product_id = ANY($2)) "
                    "AND (item_group IS NULL OR item_group = ANY($3))", customer_id, ids, groups)
    out = {}
    for p in products:
        best, rank, source = None, -1, "política da empresa"
        for r in rules:
            if r["product_id"] not in (None, p["id"]) or (r["item_group"] and r["item_group"] != p.get("item_group")):
                continue
            k = (4 if r["customer_id"] and r["product_id"] else 3 if r["product_id"] else
                 2 if r["item_group"] and not r["customer_id"] else 2.5 if r["item_group"] else 1)
            if k > rank:
                best, rank = r, k
        if best:
            source = ("exceção do cliente para o item " + p["code"] if rank == 4 else "exceção do item " + p["code"] if rank == 3
                      else f"exceção do cliente para o grupo {best['item_group']}" if rank == 2.5
                      else f"exceção do grupo {best['item_group']}" if rank == 2 else "exceção do cliente")
        mode = best["mode"] if best else pol["mode"]
        tf = best["transfer_first"] if best and best["transfer_first"] is not None else pol["transfer_first"]
        out[p["id"]] = {"mode": mode, "transfer_first": tf, "source": source}
    return out


def check_override(chosen, eff, pol):
    """The mode typed in the order must be allowed by the policy (RF-041-02, RF-041-08)."""
    if not chosen or chosen == eff["mode"] or chosen in STRICT or chosen in (pol["allowed_modes"] or []):
        return chosen or eff["mode"]
    raise ana.Error("POLICY_MODE_NOT_ALLOWED", f"a política de atendimento não permite \"{LABEL.get(chosen, chosen)}\" aqui; "
                                                f"vale \"{LABEL[eff['mode']]}\" ({eff['source']})")


def resolve(mode, product_id):
    """by_item → produce when the item is made (with an active structure), else purchase."""
    if mode != "by_item":
        return mode
    made = ana.sql_value("SELECT p.make_or_buy = 'make' AND EXISTS (SELECT 1 FROM production.structure s WHERE s.product_id = $1 AND s.active) "
                         "FROM production.item_plan p WHERE p.product_id = $1", product_id)
    return "produce" if made else "purchase"


def lot(q, minimum, multiple):
    q = max(q, minimum or ZERO)
    if multiple and multiple > 0:
        q = (q / multiple).to_integral_value(rounding=ROUND_CEILING) * multiple
    return q


def purchase_terms(product_ids):
    return {r["product_id"]: r for r in ana.sql(
        "SELECT product_id, supplier_id, lead_time_days, min_qty, multiple, price FROM supply.supplier_item "
        "WHERE preferred AND product_id = ANY($1)", list(product_ids))}


def promised_purchase(terms, pid):
    return datetime.date.today() + datetime.timedelta(days=(terms.get(pid) or {}).get("lead_time_days") or 0)


def supply_purchase(order, warehouse, lines, link):
    """One purchase request for the missing quantities, linked line by line (RF-041-04). lines: [(product, qty)];
    link: [(column values for each line)] — {"sales_order_id", "sales_order_line", "work_order_id"}. Within the
    policy's limit it becomes a purchase order by itself."""
    terms = purchase_terms(p["id"] for p, _ in lines)
    items = [{"product": p["code"], "quantity": str(lot(q, (terms.get(p["id"]) or {}).get("min_qty"), (terms.get(p["id"]) or {}).get("multiple")))}
             for p, q in lines]
    need = max(promised_purchase(terms, p["id"]) for p, _ in lines)
    r = ana.call("supply.request_purchase", reason=f"Atender o pedido de venda {order['number']}", items=items,
                 warehouse=warehouse["code"], origin="sales", need_date=need.isoformat(), submit=True)
    req = ana.sql_one("SELECT id, number, total FROM supply.purchase_request WHERE number = $1", r["number"])
    ana.sql_batch("UPDATE supply.purchase_request_line SET sales_order_id = $3, sales_order_line = $4, work_order_id = $5 "
                  "WHERE request_id = $1 AND line = $2",
                  [[req["id"], n, l.get("sales_order_id"), l.get("sales_order_line"), l.get("work_order_id")] for n, l in enumerate(link, start=1)])
    pol = policy()
    ordered = None
    orphan = [p["code"] for p, _ in lines if p["id"] not in terms]
    if pol["auto_order_max"] > 0 and req["total"] <= pol["auto_order_max"] and not orphan:
        ana.sql_exec("UPDATE supply.purchase_request SET status = 'approved', approved_by = 'política de atendimento', approved_at = now() "
                     "WHERE id = $1", req["id"])
        ordered = ana.call("supply.create_orders", requests=[req["number"]])["orders"]
    elif orphan:
        ana.log(f"solicitação {req['number']}: sem fornecedor preferido para {', '.join(orphan)} — escolha na aprovação", "warning")
    return {"request": req["number"], "orders": ordered, "need_date": need}


def supply_production(order, warehouse, product, qty, line):
    """Work order linked to the order line; components missing in the warehouse become purchases linked to the
    work order (and, through it, to the order) — RF-041-05."""
    plan = ana.sql_one("SELECT lead_time_days, lot_min, lot_multiple FROM production.item_plan WHERE product_id = $1", product["id"]) or {}
    q = lot(qty, plan.get("lot_min"), plan.get("lot_multiple"))
    due = datetime.date.today() + datetime.timedelta(days=plan.get("lead_time_days") or 0)
    # Components the work order will need (its own copy, phantoms crossed) against the warehouse's free stock.
    wo = ana.call("production.create_order", product=product["code"], quantity=str(q), due_date=due.isoformat(),
                  warehouse=warehouse["code"])
    w = ana.sql_one("SELECT id, number FROM production.work_order WHERE number = $1", wo["order"])
    ana.sql_exec("UPDATE production.work_order SET sales_order_id = $2, sales_order_line = $3 WHERE id = $1", w["id"], order["id"], line)
    need = ana.sql("SELECT c.product_id, p.code, p.kind, sum(c.qty_required) AS q FROM production.order_component c "
                   "JOIN base.product p ON p.id = c.product_id WHERE c.order_id = $1 GROUP BY 1, 2, 3", w["id"])
    free = available([n["product_id"] for n in need], warehouse["id"])
    short = [({"id": n["product_id"], "code": n["code"]}, n["q"] - max(free.get(n["product_id"], ZERO), ZERO))
             for n in need if n["kind"] == "goods" and free.get(n["product_id"], ZERO) < n["q"]]
    bought = None
    if short:
        bought = supply_purchase(order, warehouse, short, [{"sales_order_id": order["id"], "sales_order_line": line, "work_order_id": w["id"]}
                                                           for _ in short])
        due = max(due, bought["need_date"] + datetime.timedelta(days=plan.get("lead_time_days") or 0))
        ana.sql_exec("UPDATE production.work_order SET due_date = $2 WHERE id = $1 AND due_date < $2", w["id"], due)
    return {"work_order": w["number"], "quantity": q, "due": due, "components": bought}


def available(product_ids, warehouse_id):
    """Free stock (stock − reserved) per product in a warehouse (RF-041-03)."""
    if not product_ids:
        return {}
    stock = {r["product_id"]: r["q"] for r in ana.sql(
        "SELECT product_id, sum(quantity) AS q FROM inventory.stock_movement WHERE warehouse_id = $1 AND product_id = ANY($2) GROUP BY 1",
        warehouse_id, list(product_ids))}
    reserved = {r["product_id"]: r["quantity"] for r in ana.sql(
        "SELECT product_id, quantity FROM inventory.reserved WHERE warehouse_id = $1 AND product_id = ANY($2)", warehouse_id, list(product_ids))}
    return {p: stock.get(p, ZERO) - reserved.get(p, ZERO) for p in product_ids}


def release(numbers=None):
    """Held and supplied orders whose stock is there move on (RF-041-06): fulfillment back to ok and the waiting
    steps of their sales flow are evaluated again. Oldest first, so an earlier order is served first."""
    rows = ana.sql("SELECT id, number FROM sales.sales_order WHERE status = 'OPEN' AND fulfillment IN ('held', 'supply') "
                   "AND ($1::bigint[] IS NULL OR number = ANY($1)) ORDER BY number LIMIT 500 FOR UPDATE SKIP LOCKED",
                   [int(n) for n in numbers] if numbers else None)
    freed = []
    for r in rows:
        # ana:lint-ok sql_in_loop — one readiness test per waiting order (oldest first; each one changes the next)
        if ana.sql_value("SELECT sales.order_ready($1)", r["id"]):
            ana.sql_exec("UPDATE sales.sales_order SET fulfillment = 'ok' WHERE id = $1", r["id"])
            ana.sql("SELECT flow.resume_document('sales', $1)", str(r["number"]))
            freed.append(r["number"])
    return freed


def after_arrival(work_orders=(), orders=()):
    """Stock arrived (purchase receipt, production delivery): planned work orders made for a sales order are released
    when their components are there (RF-041-05), then the waiting orders move on (RF-041-06)."""
    for w in ana.sql("SELECT w.id, w.number, w.warehouse_id FROM production.work_order w WHERE w.id = ANY($1) AND w.status = 'planned' "
                     "AND w.sales_order_id IS NOT NULL", list(work_orders)):
        # ana:lint-ok sql_in_loop — the few work orders a receipt feeds
        need = ana.sql("SELECT product_id, sum(qty_required) AS q FROM production.order_component WHERE order_id = $1 GROUP BY 1", w["id"])
        free = available([n["product_id"] for n in need], w["warehouse_id"])
        if all(free.get(n["product_id"], ZERO) >= n["q"] for n in need):
            ana.call("production.release_order", order=w["number"])
            ana.log(f"ordem de produção {w['number']} liberada: os insumos chegaram")
    return release(list(orders) or None)


def linked(order_id):
    """Supply linked to an order: purchase requests (with their orders) and work orders (RF-041-07)."""
    reqs = ana.sql("SELECT DISTINCT r.number, r.status, l.work_order_id IS NOT NULL AS component FROM supply.purchase_request r "
                   "JOIN supply.purchase_request_line l ON l.request_id = r.id WHERE l.sales_order_id = $1 ORDER BY r.number", order_id)
    wos = ana.sql("SELECT number, status FROM production.work_order WHERE sales_order_id = $1 ORDER BY number", order_id)
    return reqs, wos


def cancel_effect(order_id):
    """D6: what cancelling does to the linked supply — [(kind, number, status, effect, cancel?)]."""
    reqs, wos = linked(order_id)
    out = []
    for r in reqs:
        if r["status"] in ("draft", "submitted", "approved"):
            out.append(("solicitação de compra", r["number"], r["status"], "cancelada (ainda não foi ao fornecedor)", True))
        elif r["status"] == "ordered":
            out.append(("solicitação de compra", r["number"], r["status"], "já virou ordem ao fornecedor: o que chegar fica como estoque livre", False))
    for w in wos:
        if w["status"] == "planned":
            out.append(("ordem de produção", w["number"], w["status"], "cancelada (ainda não liberada na fábrica)", True))
        elif w["status"] not in ("cancelled", "closed"):
            out.append(("ordem de produção", w["number"], w["status"], "já em curso: o produzido fica como estoque livre", False))
    return out
