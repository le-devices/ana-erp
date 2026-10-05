# ana:description Recebe mercadorias ou dá o aceite de serviços de uma ordem de compra
# ana:exposed yes
# ana:command receber
"""RF-013-05/06, RNF-013-02: one unit of work — stock, project expense, journal entry and
payable bill together or nothing. Without lines, receives everything still pending.

- goods without project → stock in (D inventory)
- service without project → acceptance (D purchased_services, cost center of the line)
- project line → project expense, no stock (D project_costs, cost center of the project)
- C suppliers; payable bill due by the order's payment terms.
The database refuses quantities above the ordered quantity plus tolerance (RNF-013-01)."""

import datetime
from decimal import Decimal, ROUND_HALF_UP

PARAMS = {
    "order": {"type": "int", "required": True, "label": "ordem de compra", "order": 1,
              "lookup": {"program": "supply.lookup", "params": {"kind": "orders"}}},
    "line": {"type": "int", "label": "linha (vazio = todas as pendentes)", "order": 2,
             "lookup": {"program": "supply.lookup", "params": {"kind": "order_lines"}, "depends": ["order"]}},
    "quantity": {"type": "decimal", "label": "quantidade recebida", "order": 3},
    "price": {"type": "decimal", "label": "preço na nota (vazio = o da ordem)", "order": 4},
    "document": {"type": "str", "label": "nota fiscal / documento", "order": 5},
    "note": {"type": "str", "label": "observação (aceite de serviço)", "order": 6},
    "lines": {"type": "list", "label": "várias linhas (integração)", "order": 7},
}
CENT = Decimal("0.01")
KIND_OF_EXPENSE = {"goods": "component", "service": "subcontract"}


def main(order, line=None, quantity=None, price=None, document=None, note=None, lines=None):
    o = ana.sql_one("SELECT o.id, o.number, o.status, o.supplier_id, o.warehouse_id, o.payment_days, p.name AS supplier "
                    "FROM supply.purchase_order o JOIN base.party p ON p.id = o.supplier_id WHERE o.number = $1 "
                    "FOR UPDATE OF o", order)
    if not o:
        raise ana.Error("ORDER_NOT_FOUND", f"ordem {order} não encontrada")
    if o["status"] not in ("sent", "partially_received"):
        raise ana.Error("INVALID_STATE", f"ordem {o['number']} não está aguardando recebimento ({o['status']})")
    current = {l["line"]: l for l in ana.sql(
        "SELECT l.line, l.product_id, pr.code, pr.description, pr.kind, l.quantity, l.received_qty, l.price, "
        "  l.project_id, l.cost_center, l.rebillable FROM supply.purchase_order_line l "
        "JOIN base.product pr ON pr.id = l.product_id WHERE l.order_id = $1 ORDER BY l.line", o["id"])}
    if lines is None:
        if line is not None:
            lines = [{"line": line, "quantity": quantity, "price": price, "note": note}]
        else:
            lines = [{"line": n, "quantity": l["quantity"] - l["received_qty"], "note": note}
                     for n, l in current.items() if l["quantity"] > l["received_qty"]]
    if not lines:
        raise ana.Error("NOTHING_TO_RECEIVE", f"nada pendente na ordem {o['number']}")

    receipt = ana.sql_value("INSERT INTO supply.receipt (order_id, document, received_by) VALUES ($1, $2, $3) RETURNING id",
                            o["id"], document, ana.context.user)
    doc = f"OC-{o['number']}/{receipt}"
    rows, journal, total = [], {}, Decimal(0)
    for item in lines:
        n = int(item.get("line") or 0)
        l = current.get(n)
        if not l:
            raise ana.Error("LINE_NOT_FOUND", f"linha {n} não existe na ordem {o['number']}")
        qty = Decimal(str(item.get("quantity") if item.get("quantity") is not None else l["quantity"] - l["received_qty"]))
        if qty <= 0:
            raise ana.Error("INVALID_VALUE", f"quantidade da linha {n} deve ser positiva")
        unit = Decimal(str(item["price"])) if item.get("price") is not None else l["price"]
        amount = (qty * unit).quantize(CENT, rounding=ROUND_HALF_UP)
        movement = expense = None
        if l["project_id"]:
            expense = ana.sql_value(
                "INSERT INTO projects.expense (project_id, kind, description, supplier_id, product_id, quantity, unit_cost, "
                "  rebillable, created_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id",
                l["project_id"], KIND_OF_EXPENSE[l["kind"]], f"{l['description']} ({doc})", o["supplier_id"],
                l["product_id"], qty, unit, l["rebillable"], ana.context.user)
            key = ("project_costs", l["cost_center"])
        elif l["kind"] == "goods":
            movement = ana.sql_value(
                "INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, created_by) "
                "VALUES ($1, $2, $3, 'in', $4, $5) RETURNING id",
                l["product_id"], o["warehouse_id"], qty, doc, ana.context.user)
            key = ("inventory", None)
        else:
            key = ("purchased_services", l["cost_center"])
        journal[key] = journal.get(key, Decimal(0)) + amount
        total += amount
        # The guard trigger refuses more than ordered × (1 + tolerance).
        ana.sql_exec("UPDATE supply.purchase_order_line SET received_qty = received_qty + $3 WHERE order_id = $1 AND line = $2",
                     o["id"], n, qty)
        ana.sql_exec("INSERT INTO supply.receipt_line (receipt_id, order_line, quantity, price, note, stock_movement_id, "
                     "  project_expense_id) VALUES ($1, $2, $3, $4, $5, $6, $7)",
                     receipt, n, qty, unit, item.get("note"), movement, expense)
        rows.append({"linha": n, "item": l["code"], "quantidade": qty, "unitário": unit, "valor": amount,
                     "destino": "projeto" if expense else ("estoque" if movement else "aceite de serviço")})

    entry = bill = None
    if total > 0:
        ana.sql("SELECT set_config('ana.cost_center', '', true)")
        entry = ana.sql_value("INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
                              f"Recebimento da ordem de compra {o['number']} — {o['supplier']}", doc, ana.context.user)
        ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit, cost_center) "
                      "VALUES ($1, finance.account_for($2), $3, $4, $5)",
                      [[entry, k, v, 0, cc] for (k, cc), v in sorted(journal.items(), key=lambda kv: (kv[0][0], kv[0][1] or ""))]
                      + [[entry, "suppliers", 0, total, None]])
        bill = ana.sql_value("INSERT INTO finance.bill (kind, party_id, document, due_date, amount, entry_id) "
                             "VALUES ('payable', $1, $2, $3, $4, $5) RETURNING id", o["supplier_id"], doc,
                             datetime.date.today() + datetime.timedelta(days=o["payment_days"]), total, entry)
    ana.sql_exec("UPDATE supply.receipt SET total = $2, entry_id = $3, bill_id = $4 WHERE id = $1", receipt, total, entry, bill)
    pending = ana.sql_value("SELECT count(*) FROM supply.purchase_order_line WHERE order_id = $1 AND received_qty < quantity",
                            o["id"])
    status = "partially_received" if pending else "received"
    ana.sql_exec("UPDATE supply.purchase_order SET status = $2 WHERE id = $1", o["id"], status)
    ana.table(rows, title=f"Recebimento {doc} — {o['supplier']}")
    return {"receipt": receipt, "document": doc, "order_status": status, "total": total, "entry": entry, "bill": bill}
