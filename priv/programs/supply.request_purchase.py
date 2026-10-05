# ana:description Solicitação de compra (mercadorias ou serviços), com envio para aprovação
# ana:exposed yes
# ana:command solicitar
"""RF-013-02. One item through the form (product/quantity) or several through `items`
([{"product", "quantity", "price"?, "supplier"?, "rebillable"?}]). Estimated price = the
preferred supplier's catalog price. Cost center: project → warehouse → company (spec 027)."""

import datetime
from decimal import Decimal

from ana_lib.supply import common

PARAMS = {
    "product": {"type": "str", "label": "item", "order": 1, "lookup": {"program": "supply.lookup", "params": {"kind": "products"}}},
    "quantity": {"type": "decimal", "label": "quantidade", "order": 2},
    "reason": {"type": "str", "required": True, "label": "motivo", "order": 3},
    "need_date": {"type": "date", "label": "data necessária", "order": 4},
    "warehouse": {"type": "str", "default": "CENTRAL", "label": "depósito de entrega", "order": 5,
                  "lookup": {"program": "supply.lookup", "params": {"kind": "warehouses"}}},
    "project": {"type": "str", "label": "projeto (vira despesa do projeto)", "order": 6,
                "lookup": {"program": "supply.lookup", "params": {"kind": "projects"}}},
    "rebillable": {"type": "bool", "default": False, "label": "refaturável ao cliente", "order": 7},
    "submit": {"type": "bool", "default": True, "label": "enviar para aprovação", "order": 8},
    "items": {"type": "list", "label": "vários itens (integração)", "order": 9},
    "origin": {"type": "str", "default": "manual", "label": "origem", "order": 10,
               "choices": [["manual", "Manual"], ["replenishment", "Reposição"], ["planning", "Planejamento"], ["project", "Projeto"]]},
    "cost_center": {"type": "str", "label": "centro de custo (vazio = do projeto ou do depósito)", "order": 11,
                    "lookup": {"program": "finance.lookup", "params": {"kind": "cost_centers"}}},
}


def main(reason, product=None, quantity=None, need_date=None, warehouse="CENTRAL", project=None, rebillable=False,
         submit=True, items=None, origin="manual", cost_center=None):
    if not items:
        if not product or not quantity:
            raise ana.Error("INVALID_ITEMS", "informe o item e a quantidade")
        items = [{"product": product, "quantity": quantity, "rebillable": rebillable}]
    if not 0 < len(items) <= 500:
        raise ana.Error("INVALID_ITEMS", "a solicitação deve ter de 1 a 500 itens")
    if need_date and need_date < datetime.date.today():
        raise ana.Error("INVALID_DATE", "a data necessária já passou")
    w = common.warehouse(warehouse)
    p = common.project(project)
    if p and origin == "manual":
        origin = "project"
    products = common.products(i.get("product", "") for i in items)
    catalog = {r["product_id"]: r for r in ana.sql(
        "SELECT product_id, supplier_id, price FROM supply.supplier_item WHERE preferred AND product_id = ANY($1)",
        [x["id"] for x in products.values()])}

    lines = []
    for n, item in enumerate(items, start=1):
        prod = products[str(item["product"]).upper()]
        qty = Decimal(str(item.get("quantity") or 0))
        if qty <= 0:
            raise ana.Error("INVALID_VALUE", f"quantidade do item {n} deve ser positiva")
        cat = catalog.get(prod["id"], {})
        price = Decimal(str(item["price"])) if item.get("price") is not None else cat.get("price", Decimal(0))
        if price < 0:
            raise ana.Error("INVALID_VALUE", f"preço do item {n} negativo")
        lines.append([n, prod["id"], qty, price, item.get("supplier") or cat.get("supplier_id"),
                      bool(item.get("rebillable", rebillable)) and p is not None])
    total = sum((l[2] * l[3] for l in lines), Decimal(0)).quantize(Decimal("0.01"))
    cc = cost_center.upper() if cost_center else ((p and p["cost_center"]) or w["cost_center"])

    req = ana.sql_one(
        "INSERT INTO supply.purchase_request (requester, need_date, reason, project_id, warehouse_id, cost_center, "
        "  origin, total) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id, number",
        ana.context.user, need_date, reason, p and p["id"], w["id"], cc, origin, total)
    ana.sql_batch("INSERT INTO supply.purchase_request_line (request_id, line, product_id, quantity, est_price, "
                  "  supplier_id, rebillable) VALUES ($1, $2, $3, $4, $5, $6, $7)", [[req["id"], *l] for l in lines])
    if submit:
        ana.sql_exec("UPDATE supply.purchase_request SET status = 'submitted' WHERE id = $1", req["id"])
    ana.log(f"solicitação {req['number']} {'enviada para aprovação' if submit else 'em rascunho'}: R$ {total}")
    ana.actions([{"label": "Abrir a bancada de compras", "program": "supply.workbench", "open": True}])
    return {"number": req["number"], "total": total, "status": "submitted" if submit else "draft", "lines": len(lines)}
