# ana:description Lança despesa ou material de protótipo no projeto
# ana:exposed yes
# ana:command expense
"""Project expense (RF-008-10). With `product`, consumes stock from `warehouse`
(document PRJ-<code>); without balance → INSUFFICIENT_STOCK."""

import datetime

from ana_lib.projects import access

PARAMS = {
    "project": {"type": "str", "required": True, "label": "projeto", "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "kind": {"type": "str", "required": True, "label": "tipo", "choices": [["component", "Componente"], ["pcb", "Placa (PCB)"], ["supplies", "Insumos"], ["subcontract", "Serviço contratado"], ["travel", "Viagem"], ["other", "Outro"]]},
    "description": {"type": "str", "required": True, "label": "descrição"},
    "unit_cost": {"type": "decimal", "label": "custo unitário (item do estoque: vazio = custo do estoque)"},
    "quantity": {"type": "decimal", "default": 1, "label": "quantidade"},
    "rebillable": {"type": "bool", "default": False, "label": "refaturável ao cliente"},
    "markup_pct": {"type": "decimal", "default": 0, "label": "acréscimo na refatura (%)"},
    "supplier": {"type": "int", "label": "fornecedor", "lookup": {"program": "supply.lookup", "params": {"kind": "suppliers"}}},
    "product": {"type": "str", "label": "item do estoque (material)", "lookup": {"program": "sales.lookup", "params": {"kind": "products"}}},
    "warehouse": {"type": "str", "default": "LAB", "label": "depósito", "lookup": {"program": "sales.lookup", "params": {"kind": "warehouses"}}},
    "expense_date": {"type": "date", "label": "data da despesa"},
}

KINDS = ("component", "pcb", "supplies", "subcontract", "travel", "other")


def main(project, kind, description, unit_cost=None, quantity=1, rebillable=False, markup_pct=0,
         supplier=None, product=None, warehouse="LAB", expense_date=None):
    p = access.project(project)
    access.require_manager(p)
    if p["status"] in ("closed",):
        raise ana.Error("PROJECT_INACTIVE", f"projeto {p['code']} está encerrado")
    if kind not in KINDS:
        raise ana.Error("INVALID_KIND", "tipo deve ser um de: " + ", ".join(KINDS))
    if quantity <= 0 or (unit_cost is not None and unit_cost < 0) or markup_pct < 0:
        raise ana.Error("INVALID_VALUE", "quantidade, custo e acréscimo devem ser válidos")

    product_id = movement_id = None
    if product:
        prod = ana.sql_one("SELECT id, kind FROM base.product WHERE code = $1 AND active", product.upper())
        if not prod:
            raise ana.Error("PRODUCT_NOT_FOUND", f"item {product} não encontrado")
        product_id = prod["id"]
        if prod["kind"] == "goods":
            w = ana.sql_one("SELECT id FROM inventory.warehouse WHERE code = $1 AND active", warehouse.upper())
            if not w:
                raise ana.Error("WAREHOUSE_NOT_FOUND", f"depósito {warehouse} não encontrado ou inativo")
            ana.sql("SELECT id FROM base.product WHERE id = $1 FOR UPDATE", product_id)
            balance = ana.sql_value(
                "SELECT COALESCE(sum(quantity), 0) FROM inventory.stock_movement "
                "WHERE product_id = $1 AND warehouse_id = $2", product_id, w["id"])
            if balance < quantity:
                raise ana.Error("INSUFFICIENT_STOCK", f"{product}: saldo {balance}, necessário {quantity}",
                                {"product": product.upper(), "balance": balance, "required": quantity})
            # Spec 038: material leaves at the stock's average cost, which is the expense's cost; the
            # database posts D project_costs (project cost center) / C inventory.
            ana.sql("SELECT set_config('ana.cost_center', COALESCE((SELECT cost_center FROM projects.project WHERE id = $1), ''), true)",
                    p["id"])
            moved = ana.sql_one(
                "INSERT INTO inventory.stock_movement (product_id, warehouse_id, quantity, kind, document, "
                "  created_by, reason) VALUES ($1, $2, $3, 'out', $4, $5, 'project_material') RETURNING id",
                product_id, w["id"], -quantity, f"PRJ-{p['code']}", ana.context.user)
            movement_id = moved["id"]
            unit_cost = ana.sql_value("SELECT unit_cost FROM inventory.stock_movement WHERE id = $1", movement_id)
    if unit_cost is None:
        raise ana.Error("INVALID_VALUE", "informe o custo unitário")

    new_id = ana.sql_value(
        "INSERT INTO projects.expense (project_id, expense_date, kind, description, supplier_id, product_id, "
        "  stock_movement_id, quantity, unit_cost, rebillable, markup_pct, created_by) "
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) RETURNING id",
        p["id"], expense_date or datetime.date.today(), kind, description, supplier, product_id,
        movement_id, quantity, unit_cost, rebillable, markup_pct, ana.context.user)
    return {"id": new_id, "stock_movement": movement_id}
