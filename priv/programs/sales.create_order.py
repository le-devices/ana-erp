# ana:description Cria pedido de venda: cliente, itens com saldo por depósito, condição de pagamento
# ana:exposed yes
# ana:command order
# ana:category Vendas/Pedidos
"""Creates an OPEN order. Price empty = the item's list price.

Fulfillment (spec 041): each goods line takes the warehouse's free stock (stock − reserved); what is missing
follows the company's policy (sales.fulfillment: refuse, hold, purchase, produce, by the item, accept — with
exceptions per item, item group, customer and customer + item), optionally transferring from other warehouses
first. Purchases and work orders it starts are linked to the order, in the same transaction. "Simular" shows
what each line would do and the promised date without creating anything. Credit (spec 031): a blocked
customer is refused unless a one-time release exists.

Integration example: {"customer": 1, "items": [{"product": "CAFE-500", "quantity": 2}], "payment_term": "PIX"}
"""

import datetime
from decimal import Decimal

from ana_lib.finance import terms
from ana_lib.util import validation as v
from ana_lib.util.format import compact, money
from ana_lib.docs import pdfs
from ana_lib.sales import fulfillment as F

# RF-020-10: the next steps of the sale, with this order filled in.
NEXT = [{"label": "Faturar este pedido", "program": "sales.invoice_order", "params": {"number": "{{result.number}}"},
         "style": "primary", "confirm": "Faturar o pedido {{result.number}}?"},
        {"label": "Expedir", "program": "logistics.ship", "params": {"order": "{{result.number}}", "_form": "1"}, "open": True},
        {"label": "Abrir pedido", "program": "docs.view", "params": {"kind": "order", "key": "{{result.number}}"}, "open": True},
        {"label": "Etapas da venda", "program": "flows.guide", "params": {"flow": "sales", "document": "{{result.number}}"},
         "open": True}]

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
    "mode": {"type": "str", "label": "se faltar estoque", "empty": "a política da empresa", "order": 5, "choices": [["refuse", "Só com estoque — recusar"], ["hold", "Só com estoque — reter até chegar"], ["purchase", "Suprir pela compra"], ["produce", "Suprir pela produção"], ["by_item", "Suprir conforme o item (fabricado ou comprado)"], ["accept", "Aceitar sem estoque definido"]]},
    "fulfill": {"type": "str", "default": "warn", "label": "transferir de outro depósito antes", "order": 5.5,
                "choices": [["warn", "Conforme a política"], ["transfer", "Transferir de outro depósito"], ["refuse", "Recusar o pedido"]]},
    "notes": {"type": "str", "label": "observações", "order": 6},
    "cost_center": {"type": "str", "label": "centro de custo", "empty": "o do depósito", "order": 7,
                    "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}},
    "simulate": {"type": "bool", "simulate": True, "label": "simular o atendimento (não grava)", "order": 8},
}
NON_SALEABLE = ("TRANSITO", "QUARENTENA")


def main(customer, items, warehouse="CENTRAL", payment_term=None, fulfill="warn", notes=None, cost_center=None, mode=None,
         simulate=False):
    v.require(0 < len(items) <= 500, "INVALID_ITEMS", "o pedido deve ter de 1 a 500 itens")
    c = ana.sql_one("SELECT id, name FROM base.party WHERE id = $1 AND active AND kind IN ('customer', 'both')", customer)
    v.require(c, "CUSTOMER_NOT_FOUND", f"cliente {customer} não encontrado")
    w = ana.sql_one("SELECT id, code, cost_center FROM inventory.warehouse WHERE code = $1 AND active", warehouse.upper())
    v.require(w and w["code"] not in NON_SALEABLE, "WAREHOUSE_NOT_FOUND", f"depósito {warehouse} não encontrado, inativo ou não vende")

    codes = sorted({str(i.get("product", "")).strip().upper() for i in items})
    products = {p["code"]: p for p in ana.sql(
        "SELECT id, code, description, kind, price, item_group FROM base.product WHERE code = ANY($1) AND active", codes)}
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

    plans = plan_lines(c, w, lines, mode, fulfill)
    refused = [x for x in plans if x and x["resolved"] == "refuse" and x["rest"] > 0]
    if refused:
        raise ana.Error("INSUFFICIENT_STOCK", "; ".join(
            f"{x['p']['code']}: faltam {compact(x['rest'])}" + (f" (há em {', '.join(f'{k}: {compact(q)}' for k, q in x['others'])})" if x["others"] else "")
            + f" — {F.LABEL['refuse']}, {x['source']}" for x in refused))
    if simulate:
        show_plan(plans, w, None)
        return {"simulated": True, "total": total, "lines": [summary(x) for x in plans if x],
                "fulfillment": situation(plans)}

    order = ana.sql_one(
        "INSERT INTO sales.sales_order (customer_id, warehouse_id, notes, created_by, cost_center, payment_term) "
        "VALUES ($1, $2, $3, $4, $5, $6) RETURNING id, number", customer, w["id"], notes, ana.context.user,
        cost_center.upper() if cost_center else w["cost_center"], term and term["code"])
    ana.sql_batch("INSERT INTO sales.sales_order_item (order_id, line, product_id, quantity, price, fulfill_mode, rule_source, from_stock, "
                  "transfer_qty, supply_qty, supply_kind, promised_date, reserve_qty) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, COALESCE($9::numeric, 0), COALESCE($10::numeric, 0), "
                  "$11, $12, $13)",
                  [[order["id"], n, p["id"], q, pr, *(line_columns(x) if x else [None] * 8)]
                   for (n, p, q, pr), x in zip(lines, plans)])

    # Transfers first (D3), then the supply linked to each line (RNF-041-02: same transaction).
    transfers = []
    for x in plans:
        if not x or not x["transfer"]:
            continue
        for code, take in x["transfer"]:
            # ana:lint-ok sql_in_loop — one transfer per source warehouse of a missing item (a handful)
            t = ana.call("logistics.transfer", action="ship", from_wh=code, to_wh=w["code"],
                         items=[{"product": x["p"]["code"], "quantity": take}], notes=f"Atender o pedido {order['number']}")
            transfers.append({"transfer": t["number"], "product": x["p"]["code"], "from": code, "quantity": take})
    supply = {"requests": [], "work_orders": []}
    buy = [x for x in plans if x and x["kind"] == "purchase"]
    if buy:
        r = F.supply_purchase(order, w, [(x["p"], x["supply"]) for x in buy],
                              [{"sales_order_id": order["id"], "sales_order_line": x["n"]} for x in buy])
        supply["requests"].append(r["request"])
        supply["orders"] = r["orders"]
        for x in buy:
            x["promised"] = r["need_date"]
    for x in plans:
        if x and x["kind"] == "production":
            # ana:lint-ok sql_in_loop — one work order per line made to order
            r = F.supply_production(order, w, x["p"], x["supply"], x["n"])
            supply["work_orders"].append(r["work_order"])
            if r["components"]:
                supply["requests"].append(r["components"]["request"])
            x["promised"] = r["due"]
    promised = [[order["id"], x["n"], x["promised"]] for x in plans if x and x["kind"]]
    if promised:
        ana.sql_batch("UPDATE sales.sales_order_item SET promised_date = $3 WHERE order_id = $1 AND line = $2", promised)
    state = situation(plans)
    if state != "ok":
        ana.sql_exec("UPDATE sales.sales_order SET fulfillment = $2 WHERE id = $1", order["id"], state)
    show_plan(plans, w, order)
    total = ana.sql_value("SELECT total FROM sales.sales_order WHERE id = $1", order["id"])
    ana.metrics([{"label": "Pedido", "value": order["number"]}, {"label": "Total", "value": money(total)},
                 {"label": "Condição", "value": term["name"] if term else "prazo padrão"},
                 {"label": "Atendimento", "value": F.STATUS[state], "status": "ok" if state == "ok" else "warn"}],
                title=f"Pedido para {c['name']}")
    if term:
        sched = terms.schedule(terms.adjusted(total, term), term)
        ana.table([{"parcela": f"{n}/{len(sched)}", "vencimento (se faturado hoje)": d, "valor": val} for n, d, val in sched],
                  title=f"Parcelas — {term['name']}")
    pdfs.publish_quietly("order", order["number"])     # spec 037: confirmation for the customer
    return {"number": order["number"], "total": total, "items": len(lines), "payment_term": term and term["code"],
            "shortages": [{"product": x["p"]["code"], "missing": x["missing"]} for x in plans if x and x["missing"] > 0],
            "transfers": transfers, "fulfillment": state, "supply": supply, "lines": [summary(x) for x in plans if x]}


def plan_lines(customer, w, lines, chosen, fulfill):
    """What each goods line does (D2, D3, D5): from the free stock, transfers, supply or the policy's answer."""
    goods = [p for _, p, _, _ in lines if p["kind"] == "goods"]
    if not goods:
        return [None] * len(lines)
    pol = F.policy()
    eff = F.effective(customer["id"], goods)
    free = F.available(sorted({p["id"] for p in goods}), w["id"])
    others = {}
    for r in ana.sql("SELECT m.product_id, x.code, sum(m.quantity) AS q FROM inventory.stock_movement m "
                     "JOIN inventory.warehouse x ON x.id = m.warehouse_id WHERE m.product_id = ANY($1) AND x.id <> $2 "
                     "AND x.code <> ALL($3) GROUP BY 1, 2 HAVING sum(m.quantity) > 0", sorted({p["id"] for p in goods}), w["id"],
                     list(NON_SALEABLE)):
        others.setdefault(r["product_id"], {})[r["code"]] = r["q"]
    today = datetime.date.today()
    out = []
    for n, p, q, _ in lines:
        if p["kind"] != "goods":
            out.append(None)
            continue
        e = eff[p["id"]]
        legacy = "refuse" if fulfill == "refuse" else None
        m = F.check_override(chosen or legacy, e, pol)
        left = max(free.get(p["id"], Decimal(0)), Decimal(0))
        take = min(left, q)
        free[p["id"]] = free.get(p["id"], Decimal(0)) - take
        missing = q - take
        x = {"n": n, "p": p, "q": q, "mode": m, "source": e["source"] if m == e["mode"] else "escolhido no pedido",
             "from_stock": take, "missing": missing, "transfer": [], "transfer_qty": Decimal(0), "supply": Decimal(0), "kind": None,
             "promised": today if missing == 0 else None, "others": sorted(others.get(p["id"], {}).items(), key=lambda z: -z[1])}
        if missing > 0 and (e["transfer_first"] or fulfill == "transfer") and m != "refuse":
            need = missing
            for code, avail in x["others"]:
                if need <= 0:
                    break
                t = min(avail, need)
                x["transfer"].append((code, t))
                others[p["id"]][code] -= t
                need -= t
            x["transfer_qty"] = missing - need
        x["rest"] = missing - x["transfer_qty"]
        x["resolved"] = F.resolve(m, p["id"]) if x["rest"] > 0 else m
        if x["rest"] > 0 and x["resolved"] in ("purchase", "produce"):
            x["supply"] = x["rest"]
            x["kind"] = "purchase" if x["resolved"] == "purchase" else "production"
            x["promised"] = F.promised_purchase(F.purchase_terms([p["id"]]), p["id"]) if x["kind"] == "purchase" else None
        elif x["rest"] == 0 and x["transfer_qty"] > 0:
            x["promised"] = today + datetime.timedelta(days=1)
        out.append(x)
    return out


def line_columns(x):
    reserve = x["from_stock"] + x["transfer_qty"] if x["resolved"] == "accept" and x["rest"] > 0 else x["q"]
    return [x["mode"], x["source"], x["from_stock"], x["transfer_qty"], x["supply"], x["kind"], x["promised"], reserve]


def situation(plans):
    rest = [x for x in plans if x and x["rest"] > 0]
    if any(x["kind"] for x in rest):
        return "supply"
    if any(x["resolved"] == "hold" for x in rest):
        return "held"
    if any(x["resolved"] == "accept" for x in rest):
        return "short"
    return "ok"


def summary(x):
    return {"line": x["n"], "product": x["p"]["code"], "quantity": x["q"], "from_stock": x["from_stock"], "transfer": x["transfer_qty"],
            "supply": x["supply"], "supply_kind": x["kind"], "mode": x["resolved"], "rule": x["source"],
            "promised_date": x["promised"].isoformat() if x["promised"] else None}


def show_plan(plans, w, order):
    """RF-041-02: per line, what comes from stock, from a transfer, from purchase or production, and when."""
    rows = []
    for x in plans:
        if not x or (x["missing"] == 0 and order is not None):
            continue
        what = {"refuse": "recusado", "hold": "retido até chegar", "accept": "aceito sem estoque — alguém decide",
                "purchase": "compra vinculada ao pedido", "produce": "ordem de produção vinculada"}.get(x["resolved"], x["resolved"])
        rows.append({"item": f"{x['p']['code']} — {x['p']['description']}", "quantidade": compact(x["q"]),
                     f"do estoque ({w['code']})": compact(x["from_stock"]), "transferir": compact(x["transfer_qty"]),
                     "falta": compact(x["rest"]), "atendimento": what if x["rest"] > 0 else "estoque e transferência",
                     "data prometida": x["promised"].strftime("%d/%m/%Y") if x["promised"] else "—",
                     "regra": f"{F.LABEL[x['mode']]} ({x['source']})",
                     "onde há": ", ".join(f"{code}: {compact(q)}" for code, q in x["others"]) or "em nenhum depósito"})
    if rows:
        ana.table(rows, title="Atendimento das linhas" + (" (simulação)" if order is None else ""))
