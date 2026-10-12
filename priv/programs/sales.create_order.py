# ana:description Cria pedido de venda: cliente, itens com saldo por depósito, condição de pagamento
# ana:exposed yes
# ana:command order
"""Creates an OPEN order. Price empty = the item's list price.

Availability: goods missing in the chosen warehouse are shown with where they exist; with
`fulfill = transfer`, the missing quantities are transferred from the warehouses that have them
(logistics.transfer: shipped now, received according to the logistics policy). Credit (spec 031):
a blocked customer is refused unless a one-time release exists.

Integration example: {"customer": 1, "items": [{"product": "CAFE-500", "quantity": 2}], "payment_term": "PIX"}
"""

from decimal import Decimal

from ana_lib.finance import terms
from ana_lib.util import validation as v
from ana_lib.util.format import compact, money
from ana_lib.docs import pdfs

PARAMS = {
    "customer": {"type": "int", "required": True, "label": "cliente", "order": 1,
                 "lookup": {"program": "sales.lookup", "params": {"kind": "customers"}}},
    "warehouse": {"type": "str", "default": "CENTRAL", "label": "depósito que atende", "order": 2,
                  "lookup": {"program": "sales.lookup", "params": {"kind": "warehouses"}}},
    "payment_term": {"type": "str", "label": "condição de pagamento", "empty": "a do cliente", "order": 3,
                     "lookup": {"program": "finance.lookup", "params": {"kind": "payment_terms"}}},
    "items": {"type": "list", "required": True, "label": "itens", "order": 4, "add_label": "Adicionar item", "columns": {
        "product": {"type": "str", "required": True, "label": "item",
                    "lookup": {"program": "sales.lookup", "params": {"kind": "products"}, "depends": ["warehouse"]}},
        "quantity": {"type": "decimal", "required": True, "default": 1, "label": "quantidade"},
        "price": {"type": "decimal", "label": "preço unitário (vazio = tabela)"}}},
    "fulfill": {"type": "str", "default": "warn", "label": "se faltar no depósito", "order": 5,
                "choices": [["warn", "Só avisar"], ["transfer", "Transferir de outro depósito"], ["refuse", "Recusar o pedido"]]},
    "notes": {"type": "str", "label": "observações", "order": 6},
    "cost_center": {"type": "str", "label": "centro de custo", "empty": "o do depósito", "order": 7,
                    "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}},
}
NON_SALEABLE = ("TRANSITO", "QUARENTENA")


def main(customer, items, warehouse="CENTRAL", payment_term=None, fulfill="warn", notes=None, cost_center=None):
    v.require(0 < len(items) <= 500, "INVALID_ITEMS", "o pedido deve ter de 1 a 500 itens")
    c = ana.sql_one("SELECT id, name FROM base.party WHERE id = $1 AND active AND kind IN ('customer', 'both')", customer)
    v.require(c, "CUSTOMER_NOT_FOUND", f"cliente {customer} não encontrado")
    w = ana.sql_one("SELECT id, code, cost_center FROM inventory.warehouse WHERE code = $1 AND active", warehouse.upper())
    v.require(w and w["code"] not in NON_SALEABLE, "WAREHOUSE_NOT_FOUND", f"depósito {warehouse} não encontrado, inativo ou não vende")

    codes = sorted({str(i.get("product", "")).strip().upper() for i in items})
    products = {p["code"]: p for p in ana.sql(
        "SELECT id, code, description, kind, price FROM base.product WHERE code = ANY($1) AND active", codes)}
    missing = [code for code in codes if code not in products]
    v.require(not missing, "PRODUCT_NOT_FOUND", f"itens inexistentes: {', '.join(missing)}")

    lines = []
    for n, item in enumerate(items, start=1):
        p = products[str(item["product"]).strip().upper()]
        qty = v.positive_decimal(item.get("quantity"), f"quantidade do item {n}")
        price = v.decimal(item["price"], f"preço do item {n}") if item.get("price") not in (None, "") else p["price"]
        v.require(price >= 0, "INVALID_VALUE", f"preço do item {n} negativo")
        lines.append([n, p, qty, price])
    total = sum((q * pr for _, _, q, pr in lines), Decimal(0)).quantize(Decimal("0.01"))

    term = terms.term_for(customer, payment_term.upper() if payment_term else None)
    if term:
        terms.require_allowed(customer, term, total)
    terms.check_credit(customer, total, "order")

    # Availability in the chosen warehouse (goods only), one aggregate query.
    need = {}
    for _, p, q, _ in lines:
        if p["kind"] == "goods":
            need[p["id"]] = need.get(p["id"], Decimal(0)) + q
    stock = {}
    for r in ana.sql("SELECT m.product_id, w.code, sum(m.quantity) AS q FROM inventory.stock_movement m "
                     "JOIN inventory.warehouse w ON w.id = m.warehouse_id WHERE m.product_id = ANY($1) "
                     "AND w.code <> ALL($2) GROUP BY 1, 2 HAVING sum(m.quantity) > 0", sorted(need), list(NON_SALEABLE)):
        stock.setdefault(r["product_id"], {})[r["code"]] = r["q"]
    reserved = {r["product_id"]: r["quantity"] for r in ana.sql(
        "SELECT product_id, quantity FROM inventory.reserved WHERE warehouse_id = $1 AND product_id = ANY($2)", w["id"], sorted(need))}
    short = []
    for pid, q in need.items():
        free = stock.get(pid, {}).get(w["code"], Decimal(0)) - reserved.get(pid, Decimal(0))
        if free < q:
            others = sorted(((code, qq) for code, qq in stock.get(pid, {}).items() if code != w["code"]), key=lambda x: -x[1])
            short.append({"product_id": pid, "missing": q - max(free, Decimal(0)), "free": free, "others": others})
    if short and fulfill == "refuse":
        names = {p["id"]: p["code"] for _, p, _, _ in lines}
        raise ana.Error("INSUFFICIENT_STOCK", "; ".join(f"{names[s['product_id']]}: faltam {compact(s['missing'])}" for s in short))

    order = ana.sql_one(
        "INSERT INTO sales.sales_order (customer_id, warehouse_id, notes, created_by, cost_center, payment_term) "
        "VALUES ($1, $2, $3, $4, $5, $6) RETURNING id, number", customer, w["id"], notes, ana.context.user,
        cost_center.upper() if cost_center else w["cost_center"], term and term["code"])
    ana.sql_batch("INSERT INTO sales.sales_order_item (order_id, line, product_id, quantity, price) VALUES ($1, $2, $3, $4, $5)",
                  [[order["id"], n, p["id"], q, pr] for n, p, q, pr in lines])

    transfers, rows = [], []
    by_code = {p["id"]: p for _, p, _, _ in lines}
    for s in short:
        p = by_code[s["product_id"]]
        plan, left = [], s["missing"]
        for code, qq in s["others"]:
            if left <= 0:
                break
            take = min(qq, left)
            plan.append((code, take))
            left -= take
        if fulfill == "transfer" and plan:
            for code, take in plan:
                # ana:lint-ok sql_in_loop — one transfer per source warehouse of a missing item (a handful)
                t = ana.call("logistics.transfer", action="ship", from_wh=code, to_wh=w["code"],
                             items=[{"product": p["code"], "quantity": take}], notes=f"Atender o pedido {order['number']}")
                transfers.append({"transfer": t["number"], "product": p["code"], "from": code, "quantity": take})
        rows.append({"item": f"{p['code']} — {p['description']}", f"livre em {w['code']}": compact(s["free"]), "falta": compact(s["missing"]),
                     "onde há": ", ".join(f"{code}: {compact(qq)}" for code, qq in s["others"]) or "em nenhum depósito",
                     "_actions": [] if fulfill == "transfer" or not plan else [
                         {"label": f"Transferir de {code}", "program": "logistics.transfer", "style": "primary",
                          "params": {"action": "ship", "from_wh": code, "to_wh": w["code"],
                                     "items": [{"product": p["code"], "quantity": str(take)}],
                                     "notes": f"Atender o pedido {order['number']}"}} for code, take in plan]})
    if rows:
        ana.table(rows, title="Transferências pedidas para atender" if fulfill == "transfer" else "Itens que faltam no depósito")
    total = ana.sql_value("SELECT total FROM sales.sales_order WHERE id = $1", order["id"])
    ana.metrics([{"label": "Pedido", "value": order["number"]}, {"label": "Total", "value": money(total)},
                 {"label": "Condição", "value": term["name"] if term else "prazo padrão"},
                 {"label": "Faltas", "value": len(short), "status": "warn" if short else "ok"}], title=f"Pedido para {c['name']}")
    if term:
        sched = terms.schedule(terms.adjusted(total, term), term)
        ana.table([{"parcela": f"{n}/{len(sched)}", "vencimento (se faturado hoje)": d, "valor": val} for n, d, val in sched],
                  title=f"Parcelas — {term['name']}")
    ana.actions([{"label": "Abrir pedido", "program": "docs.view", "params": {"kind": "order", "key": str(order["number"])}, "open": True},
                 {"label": "Faturar agora", "program": "sales.invoice_order", "params": {"number": order["number"]},
                  "style": "primary", "confirm": f"Faturar o pedido {order['number']}?"},
                 {"label": "Expedir", "program": "logistics.ship", "params": {"order": order["number"], "_form": "1"}, "open": True}],
                title="Próximo passo")
    pdfs.publish_quietly("order", order["number"])     # spec 037: confirmation for the customer
    return {"number": order["number"], "total": total, "items": len(lines), "payment_term": term and term["code"],
            "shortages": [{"product": by_code[s["product_id"]]["code"], "missing": s["missing"]} for s in short],
            "transfers": transfers}
