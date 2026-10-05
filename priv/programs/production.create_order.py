# ana:description Cria ordem de produção (componentes e operações copiados da estrutura e do roteiro ativos)
# ana:exposed yes
"""RF-014-06. The order keeps its own copy of components (phantoms crossed, scrap included),
operations and unit costs, so later changes to structure or routing never alter it.
Standard cost = components × cost + standard hours × resource cost per hour."""

import datetime

from ana_lib.production import common

PARAMS = {
    "product": {"type": "str", "required": True, "label": "item", "order": 1, "lookup": {"program": "production.lookup", "params": {"kind": "made"}}},
    "quantity": {"type": "decimal", "required": True, "label": "quantidade", "order": 2},
    "due_date": {"type": "date", "required": True, "label": "data de término", "order": 3},
    "start_date": {"type": "date", "label": "início (vazio = término − prazo do item)", "order": 4},
    "warehouse": {"type": "str", "label": "depósito", "order": 5, "lookup": {"program": "production.lookup", "params": {"kind": "warehouses"}}},
    "project": {"type": "str", "label": "projeto (protótipos: custo vai para o projeto)", "order": 6,
                "lookup": {"program": "projects.lookup", "params": {"kind": "projects"}}},
    "priority": {"type": "int", "default": 5, "label": "prioridade (1 = mais alta)", "order": 7},
    "suggestion": {"type": "int", "label": "sugestão de origem", "order": 8},
}


def main(product, quantity, due_date, start_date=None, warehouse=None, project=None, priority=5, suggestion=None):
    p = common.product(product)
    if quantity <= 0:
        raise ana.Error("INVALID_VALUE", "quantidade deve ser positiva")
    plan = ana.sql_one("SELECT lead_time_days, warehouse_id FROM production.item_plan WHERE product_id = $1", p["id"]) or {}
    if warehouse:
        wh = common.warehouse(warehouse)
    elif plan.get("warehouse_id"):
        wh = ana.sql_one("SELECT id, code, cost_center FROM inventory.warehouse WHERE id = $1", plan["warehouse_id"])
    else:
        wh = common.warehouse("CENTRAL")
    start = start_date or (due_date - datetime.timedelta(days=plan.get("lead_time_days") or 0))
    if start > due_date:
        raise ana.Error("INVALID_DATE", "o início não pode ser depois do término")
    prj = None
    if project:
        prj = ana.sql_one("SELECT id, code, cost_center, status FROM projects.project WHERE code = $1", project.upper())
        if not prj or prj["status"] == "closed":
            raise ana.Error("PROJECT_NOT_FOUND", f"projeto {project} não encontrado ou encerrado")
    structure = ana.sql_value("SELECT id FROM production.structure WHERE product_id = $1 AND active", p["id"])
    comps = common.explode(p["id"], quantity)
    costs = common.unit_costs([c for c, _ in comps])
    routing = ana.sql_value("SELECT id FROM production.routing WHERE product_id = $1 AND active", p["id"])
    ops = ana.sql("SELECT o.seq, o.resource_code, o.description, o.setup_min, o.run_min, r.cost_per_hour "
                  "FROM production.operation o JOIN production.resource r ON r.code = o.resource_code "
                  "WHERE o.routing_id = $1 ORDER BY o.seq", routing) if routing else []
    std_ops = [(o, ((o["setup_min"] + o["run_min"] * quantity) / 60).quantize(common.Decimal("0.001"))) for o in ops]
    std_cost = common.money(sum((q * costs.get(c, common.ZERO) for c, q in comps), common.ZERO)
                            + sum((h * o["cost_per_hour"] for o, h in std_ops), common.ZERO))
    cc = (prj and prj["cost_center"]) or wh["cost_center"]
    o = ana.sql_one("INSERT INTO production.work_order (product_id, quantity, structure_id, routing_id, warehouse_id, start_date, "
                    "  due_date, priority, project_id, cost_center, std_cost, suggestion_id, created_by) "
                    "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) RETURNING id, number",
                    p["id"], quantity, structure, routing, wh["id"], start, due_date, priority, prj and prj["id"], cc,
                    std_cost, suggestion, ana.context.user)
    ana.sql_batch("INSERT INTO production.order_component (order_id, line, product_id, qty_required, unit_cost) "
                  "VALUES ($1, $2, $3, $4, $5)",
                  [[o["id"], n, c, q, costs.get(c, 0)] for n, (c, q) in enumerate(sorted(comps), start=1)])
    if std_ops:
        ana.sql_batch("INSERT INTO production.order_operation (order_id, seq, resource_code, description, std_hours, cost_per_hour) "
                      "VALUES ($1, $2, $3, $4, $5, $6)",
                      [[o["id"], op["seq"], op["resource_code"], op["description"], h, op["cost_per_hour"]] for op, h in std_ops])
    ana.actions([{"label": "Liberar a ordem", "program": "production.release_order", "params": {"order": o["number"]},
                  "style": "primary"}], title="Próximo passo")
    return {"order": o["number"], "components": len(comps), "operations": len(std_ops), "std_cost": std_cost,
            "start_date": start}
