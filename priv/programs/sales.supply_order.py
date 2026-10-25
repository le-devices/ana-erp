# ana:description Supre um pedido aceito com falta: compra ou produção vinculada ao pedido
# ana:menu no
# ana:category Vendas/Atendimento
"""Spec 041 (D2.6, RF-041-07): an order accepted without stock waits for someone to decide; this is the decision.
The missing quantities become a purchase (or work orders) linked to the order lines, which then reserve them."""

from ana_lib.sales import fulfillment as F

PARAMS = {"number": {"type": "int", "required": True, "label": "pedido", "lookup": {"program": "sales.lookup", "params": {"kind": "orders"}}},
          "kind": {"type": "str", "required": True, "default": "purchase", "label": "suprir por",
                   "choices": [["purchase", "Compra"], ["produce", "Produção"]]}}


def main(number, kind="purchase"):
    o = ana.sql_one("SELECT o.id, o.number, o.status, o.fulfillment, w.id AS wid, w.code FROM sales.sales_order o "
                    "JOIN inventory.warehouse w ON w.id = o.warehouse_id WHERE o.number = $1 FOR UPDATE OF o", number)
    if not o:
        raise ana.Error("ORDER_NOT_FOUND", f"pedido {number} não encontrado")
    if o["status"] != "OPEN" or o["fulfillment"] != "short":
        raise ana.Error("INVALID_STATE", f"pedido {number} não está aceito com falta")
    lines = ana.sql("SELECT i.line, i.quantity, COALESCE(i.reserve_qty, i.quantity) AS reserved, p.id, p.code FROM sales.sales_order_item i "
                    "JOIN base.product p ON p.id = i.product_id WHERE i.order_id = $1 AND p.kind = 'goods' "
                    "AND COALESCE(i.reserve_qty, i.quantity) < i.quantity ORDER BY i.line", o["id"])
    if not lines:
        raise ana.Error("NOTHING_TO_SUPPLY", f"pedido {number} não tem falta")
    order, wh = {"id": o["id"], "number": o["number"]}, {"id": o["wid"], "code": o["code"]}
    out = []
    if kind == "purchase":
        r = F.supply_purchase(order, wh, [({"id": l["id"], "code": l["code"]}, l["quantity"] - l["reserved"]) for l in lines],
                              [{"sales_order_id": o["id"], "sales_order_line": l["line"]} for l in lines])
        dates = {l["line"]: r["need_date"] for l in lines}
        out.append(r["request"])
    elif kind == "produce":
        dates = {}
        for l in lines:
            # ana:lint-ok sql_in_loop — one work order per line made to order
            r = F.supply_production(order, wh, {"id": l["id"], "code": l["code"]}, l["quantity"] - l["reserved"], l["line"])
            dates[l["line"]] = r["due"]
            out.append(r["work_order"])
    else:
        raise ana.Error("INVALID_PARAMETER", "suprir por compra ou produção")
    ana.sql_batch("UPDATE sales.sales_order_item SET supply_qty = quantity - COALESCE(reserve_qty, quantity), supply_kind = $3, "
                  "promised_date = $4, reserve_qty = quantity WHERE order_id = $1 AND line = $2",
                  [[o["id"], l["line"], "purchase" if kind == "purchase" else "production", dates[l["line"]]] for l in lines])
    ana.sql_exec("UPDATE sales.sales_order SET fulfillment = 'supply' WHERE id = $1", o["id"])
    ana.log(f"pedido {number}: {'compra' if kind == 'purchase' else 'produção'} vinculada ({', '.join(map(str, out))})")
    return {"number": number, "kind": kind, "supply": out}
