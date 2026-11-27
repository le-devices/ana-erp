# ana:description Recebe mercadorias ou dá o aceite de serviços de uma ordem de compra
# ana:exposed yes
# ana:command receber
# ana:category Compras/Recebimento e notas
"""RF-013-05/06, RNF-013-02: one unit of work — stock, project expense, journal entry and
payable bill together or nothing. Without lines, receives everything still pending.

- goods without project → stock in (D inventory)
- service without project → acceptance (D purchased_services, cost center of the line)
- project line → project expense, no stock (D project_costs, cost center of the project)
- C suppliers; payable bill due by the order's payment terms.
The database refuses quantities above the ordered quantity plus tolerance (RNF-013-01)."""

import datetime
from decimal import Decimal, ROUND_HALF_UP

from ana_lib.finance import currency
from ana_lib.sales import fulfillment

PARAMS = {
    "order": {"type": "int", "required": True, "label": "ordem de compra", "order": 1,
              "lookup": {"program": "supply.lookup", "params": {"kind": "orders"}}},
    "line": {"type": "int", "label": "linha (vazio = todas as pendentes)", "order": 2,
             "lookup": {"program": "supply.lookup", "params": {"kind": "order_lines"}, "depends": ["order"]}},
    "quantity": {"type": "decimal", "label": "quantidade recebida", "order": 3},
    "price": {"type": "decimal", "label": "preço na nota, na moeda da ordem (vazio = o da ordem)", "order": 4},
    "document": {"type": "str", "label": "nota fiscal / documento", "order": 5, "scan": True},
    "note": {"type": "str", "label": "observação (aceite de serviço)", "order": 6},
    "lines": {"type": "list", "label": "várias linhas de uma vez", "order": 7, "columns": {
        "line": {"type": "int", "required": True, "label": "linha",
                 "lookup": {"program": "supply.lookup", "params": {"kind": "order_lines"}, "depends": ["order"]}},
        "quantity": {"type": "decimal", "label": "quantidade (vazio = o pendente)"},
        "price": {"type": "decimal", "label": "preço na nota, na moeda da ordem (vazio = o da ordem)"},
        "note": {"type": "str", "label": "observação"}}},
}
CENT = Decimal("0.01")
KIND_OF_EXPENSE = {"goods": "component", "service": "subcontract"}


def main(order, line=None, quantity=None, price=None, document=None, note=None, lines=None):
    o = ana.sql_one("SELECT o.id, o.number, o.status, o.supplier_id, o.warehouse_id, o.payment_days, o.currency, p.name AS supplier "
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
    # Spec 009 (D9): the customer's rules before receiving; they may refuse or adjust document and note.
    adj = ana.extend("before_receive_purchase", {"order": o["number"], "supplier_id": o["supplier_id"], "document": document,
                                                 "note": note, "lines": lines})
    document, note = adj.get("document", document), adj.get("note", note)
    if lines is None:
        if line is not None:
            lines = [{"line": line, "quantity": quantity, "price": price, "note": note}]
        else:
            lines = [{"line": n, "quantity": l["quantity"] - l["received_qty"], "note": note}
                     for n, l in current.items() if l["quantity"] > l["received_qty"]]
    if not lines:
        raise ana.Error("NOTHING_TO_RECEIVE", f"nada pendente na ordem {o['number']}")

    # Spec 069 (T-069-01): an order in dollars or euros is received at the rate of the day — stock, project costs,
    # journal and bill in reais; the receipt keeps the currency and the rate it used. Without a rate: refused.
    rate = currency.rate(o["currency"])
    receipt = ana.sql_value("INSERT INTO supply.receipt (order_id, document, received_by, currency, exchange_rate) "
                            "VALUES ($1, $2, $3, $4, $5) RETURNING id", o["id"], document, ana.context.user, o["currency"], rate)
    doc = f"OC-{o['number']}/{receipt}"
    rows, journal, total, todo = [], {}, Decimal(0), []
    for item in lines:
        n = int(item.get("line") or 0)
        l = current.get(n)
        if not l:
            raise ana.Error("LINE_NOT_FOUND", f"linha {n} não existe na ordem {o['number']}")
        qty = Decimal(str(item.get("quantity") if item.get("quantity") is not None else l["quantity"] - l["received_qty"]))
        if qty <= 0:
            raise ana.Error("INVALID_VALUE", f"quantidade da linha {n} deve ser positiva")
        given = Decimal(str(item["price"])) if item.get("price") is not None else l["price"]   # in the order's currency
        unit = (Decimal(str(given)) * rate).quantize(currency.UNIT, rounding=ROUND_HALF_UP) if rate != 1 else given
        amount = (qty * unit).quantize(CENT, rounding=ROUND_HALF_UP)
        dest = "project" if l["project_id"] else ("stock" if l["kind"] == "goods" else "service")
        # Spec 038: goods are valued and posted by the database (D inventory / C goods_received);
        # here the receipt clears goods_received against the supplier.
        key = {"project": ("project_costs", l["cost_center"]), "stock": ("goods_received", None),
               "service": ("purchased_services", l["cost_center"])}[dest]
        journal[key] = journal.get(key, Decimal(0)) + amount
        total += amount
        todo.append((n, l, qty, unit, amount, dest, item.get("note")))

    # Ids reserved up front so every write below is a single batch (no round trip per line).
    n_moves = sum(1 for t in todo if t[5] == "stock")
    n_exp = sum(1 for t in todo if t[5] == "project")
    ids = ana.sql_one("SELECT ARRAY(SELECT nextval('inventory.stock_movement_id_seq') FROM generate_series(1, $1)) AS moves, "
                      "ARRAY(SELECT nextval('projects.expense_id_seq') FROM generate_series(1, $2)) AS expenses",
                      n_moves, n_exp)
    moves, expenses = iter(ids["moves"]), iter(ids["expenses"])
    move_rows, exp_rows, receipt_rows = [], [], []
    for n, l, qty, unit, amount, dest, note in todo:
        movement = expense = None
        if dest == "stock":
            movement = next(moves)
            move_rows.append([movement, l["product_id"], o["warehouse_id"], qty, doc, ana.context.user, str(unit)])
        elif dest == "project":
            expense = next(expenses)
            exp_rows.append([expense, l["project_id"], KIND_OF_EXPENSE[l["kind"]], f"{l['description']} ({doc})",
                             o["supplier_id"], l["product_id"], qty, unit, l["rebillable"], ana.context.user])
        receipt_rows.append([receipt, n, qty, unit, note, movement, expense])
        rows.append({"linha": n, "item": l["code"], "quantidade": qty, "unitário": unit, "valor": amount,
                     "destino": {"project": "projeto", "stock": "estoque", "service": "aceite de serviço"}[dest]})
    if move_rows:
        ana.sql_batch("INSERT INTO inventory.stock_movement (id, product_id, warehouse_id, quantity, kind, document, created_by, "
                      "  reason, unit_cost) VALUES ($1, $2, $3, $4, 'in', $5, $6, 'purchase', $7::numeric)", move_rows)
    if exp_rows:
        ana.sql_batch("INSERT INTO projects.expense (id, project_id, kind, description, supplier_id, product_id, quantity, "
                      "  unit_cost, rebillable, created_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)", exp_rows)
    # The guard trigger refuses more than ordered × (1 + tolerance), line by line.
    ana.sql_exec("UPDATE supply.purchase_order_line l SET received_qty = l.received_qty + x.qty "
                 "FROM (SELECT line, sum(qty::numeric) AS qty FROM unnest($2::int[], $3::text[]) AS u(line, qty) GROUP BY line) x "
                 "WHERE l.order_id = $1 AND l.line = x.line",
                 o["id"], [t[0] for t in todo], [str(t[2]) for t in todo])
    ana.sql_batch("INSERT INTO supply.receipt_line (receipt_id, order_line, quantity, price, note, stock_movement_id, "
                  "  project_expense_id) VALUES ($1, $2, $3, $4, $5, $6, $7)", receipt_rows)

    entry = bill = None
    # Spec 038 (RF-038-10): with matching, the receipt only credits "goods received"; the supplier's bill is born
    # from its invoice (supply.register_invoice), compared with what was received.
    matching = ana.sql_value("SELECT supplier_invoice = 'match' FROM supply.policy WHERE id = 1")
    if total > 0 and matching:
        ana.sql("SELECT set_config('ana.cost_center', '', true)")
        others = {k: v for k, v in journal.items() if k[0] != "goods_received"}
        if others:
            entry = ana.sql_value("INSERT INTO finance.journal_entry (memo, document, created_by) VALUES ($1, $2, $3) RETURNING id",
                                  f"Recebimento da ordem de compra {o['number']} — {o['supplier']} (a faturar)", doc, ana.context.user)
            ana.sql_batch("INSERT INTO finance.journal_line (entry_id, account, debit, credit, cost_center) "
                          "VALUES ($1, finance.account_for($2), $3, $4, $5)",
                          [[entry, k, v, 0, cc] for (k, cc), v in sorted(others.items(), key=lambda kv: (kv[0][0], kv[0][1] or ""))]
                          + [[entry, "goods_received", 0, sum(others.values()), None]])
    elif total > 0:
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
    result = {"receipt": receipt, "document": doc, "order_status": status, "total": total, "entry": entry, "bill": bill}
    if o["currency"] != "BRL":
        result.update({"currency": o["currency"], "exchange_rate": rate})
    # Spec 041: what was bought for a sales order (or for the work order that serves it) frees it to move on.
    links = ana.sql("SELECT DISTINCT rl.sales_order_id, rl.work_order_id FROM supply.purchase_order_line pl "
                    "JOIN supply.purchase_request_line rl ON rl.request_id = pl.request_id AND rl.line = pl.request_line "
                    "WHERE pl.order_id = $1 AND rl.sales_order_id IS NOT NULL", o["id"])
    if links:
        result["released"] = fulfillment.after_arrival([l["work_order_id"] for l in links if l["work_order_id"]])
    ana.extend("after_receive_purchase", result)
    return result
