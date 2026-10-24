# ana:description Devolve ao fornecedor mercadoria recebida: sai do estoque pelo preço da compra e vira crédito com o fornecedor (compensado nos títulos)
# ana:exposed yes
# ana:category Compras/Recebimento e notas
"""Spec 038 (RF-038-10). The database posts D supplier credits / C inventory at the purchase price; the credit
(receivable bill, account supplier credits) is offset against the supplier's open bills when the policy says so."""

from decimal import Decimal

from ana_lib.finance import banking
from ana_lib.util import validation as v

PARAMS = {"order": {"type": "int", "required": True, "label": "ordem de compra", "lookup": {"program": "supply.lookup", "params": {"kind": "orders"}}},
          "line": {"type": "int", "required": True, "label": "linha", "lookup": {"program": "supply.lookup", "params": {"kind": "order_lines"}, "depends": ["order"]}},
          "quantity": {"type": "decimal", "required": True, "label": "quantidade"},
          "reason": {"type": "str", "required": True, "label": "motivo"}}


def main(order, line, quantity, reason):
    v.require(len((reason or "").strip()) >= 3, "INVALID_PARAMETER", "diga o motivo da devolução")
    q = v.positive_decimal(quantity, "quantidade")
    o = ana.sql_one("SELECT o.id, o.number, o.supplier_id, o.warehouse_id, l.product_id, l.price, l.received_qty, p.kind, p.code "
                    "FROM supply.purchase_order o JOIN supply.purchase_order_line l ON l.order_id = o.id "
                    "JOIN base.product p ON p.id = l.product_id WHERE o.number = $1 AND l.line = $2 FOR UPDATE OF o", order, line)
    v.require(o, "LINE_NOT_FOUND", f"linha {line} da ordem {order} não encontrada")
    v.require(o["kind"] == "goods", "NOT_STOCKABLE", "só mercadorias voltam ao fornecedor por aqui")
    returned = ana.sql_value("SELECT COALESCE(-sum(quantity), 0) FROM inventory.stock_movement WHERE document LIKE $1 AND product_id = $2",
                             f"DEVF-OC-{order}-%", o["product_id"])
    v.require(q <= Decimal(o["received_qty"]) - Decimal(returned), "OVER_RETURN", "quantidade acima do que foi recebido e não devolvido")
    bal = ana.sql_value("SELECT COALESCE(sum(quantity), 0) FROM inventory.stock_movement WHERE product_id = $1 AND warehouse_id = $2",
                        o["product_id"], o["warehouse_id"])
    v.require(bal >= q, "INSUFFICIENT_STOCK", f"{o['code']}: saldo {bal} no depósito da ordem")
    n = ana.sql_value("SELECT count(*) + 1 FROM finance.bill WHERE document LIKE $1", f"DEVF-OC-{order}-%")
    doc = f"DEVF-OC-{order}-{n}"
    m = ana.sql_one("INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, created_by, reason, unit_cost) "
                    "VALUES ($1, $2, $3, 'out', $4, $5, 'purchase_return', $6) RETURNING id", o["product_id"], o["warehouse_id"], -q, doc,
                    ana.context.user, o["price"])
    mv = ana.sql_one("SELECT value, entry_id FROM inventory.stock_movement WHERE id = $1", m["id"])
    credit = -Decimal(mv["value"])
    bill = ana.sql_value("INSERT INTO finance.bill (kind, party_id, document, due_date, amount, entry_id, account) "
                         "VALUES ('receivable', $1, $2, current_date + 30, $3, $4, finance.account_for('supplier_credits')) RETURNING id",
                         o["supplier_id"], doc, credit, mv["entry_id"])
    offsets = banking.offset(o["supplier_id"], ana.context.user) if banking.policy()["auto_offset"] else []
    ana.log(f"{doc}: {q} {o['code']} devolvido(s) ao fornecedor — {reason.strip()}")
    return {"document": doc, "credit": credit, "bill": bill, "offsets": len(offsets)}
