# ana:description Encerra a ordem: apura o custo real, a variação contra o padrão e lança no estoque ou no projeto
# ana:exposed yes
# ana:category Produção/Ordens de produção
# ana:confirm A ordem é encerrada: o custo real e a variação são apurados e lançados no estoque ou no projeto. Depois de encerrada, não se aponta mais nada nela.
"""RF-014-06/09, CA-014-03/06. Actual cost = components issued (at the value they left the stock)
+ hours reported × cost per hour (immutable after closing). Order of a project: D project_costs +
project expense / C work_in_process. Otherwise the finished goods already entered the stock at the
standard cost (spec 038): what is left in work_in_process goes to production_variance.
Variance = actual − standard."""

from decimal import Decimal

from ana_lib.production import common

PARAMS = {"order": {"type": "int", "required": True, "label": "ordem", "lookup": {"program": "production.lookup", "params": {"kind": "orders"}}}}


def main(order):
    o = common.order(order, lock=True)
    if o["status"] != "completed":
        raise ana.Error("INVALID_STATE", f"ordem {o['number']} não está concluída")
    doc = f"OP-{o['number']}"
    comp = ana.sql_value("SELECT COALESCE(-sum(value), 0) FROM inventory.stock_movement WHERE document = $1 AND reason = 'production_issue'",
                         doc)
    delivered = ana.sql_value("SELECT COALESCE(sum(value), 0) FROM inventory.stock_movement WHERE document = $1 "
                              "AND reason = 'production_receipt'", doc)
    hours = ana.sql_value("SELECT COALESCE(sum(cost), 0) FROM production.operation_report WHERE order_id = $1", o["id"])
    actual = common.money(Decimal(comp) + Decimal(hours))
    variance = common.money(actual - (o["std_cost"] or 0))
    if o["project_id"]:
        cc = ana.sql_value("SELECT cost_center FROM projects.project WHERE id = $1", o["project_id"])
        common.post(f"Custo da ordem de produção {o['number']} (protótipos) para o projeto", doc,
                    [("@project_costs", actual, 0, cc), ("@work_in_process", 0, actual, None)])
        units = o["good_qty"] if o["good_qty"] > 0 else Decimal(1)
        ana.sql_exec("INSERT INTO projects.expense (project_id, kind, description, product_id, quantity, unit_cost, created_by) "
                     "VALUES ($1, 'other', $2, $3, $4, $5, $6)", o["project_id"],
                     f"Ordem de produção {o['number']}: {o['description']} ({o['good_qty']} boas, {o['scrap_qty']} refugo)",
                     o["product_id"], units, (actual / units).quantize(Decimal("0.0001")), ana.context.user)
    else:
        rest = common.money(actual - Decimal(delivered))
        common.post(f"Variação de custo da ordem de produção {o['number']}", doc,
                    [("@production_variance", rest, 0, None), ("@work_in_process", 0, rest, None)] if rest > 0 else
                    [("@work_in_process", -rest, 0, None), ("@production_variance", 0, -rest, None)])
    ana.sql_exec("UPDATE production.work_order SET actual_cost = $2, variance = $3, status = 'closed', closed_at = now() "
                 "WHERE id = $1", o["id"], actual, variance)
    unit = (actual / o["good_qty"]).quantize(Decimal("0.0001")) if o["good_qty"] else None
    ana.metrics([{"label": "Custo real", "value": f"R$ {actual}"}, {"label": "Custo padrão", "value": f"R$ {o['std_cost']}"},
                 {"label": "Variação", "value": f"R$ {variance}", "status": "bad" if variance > 0 else "ok"},
                 {"label": "Custo por unidade boa", "value": f"R$ {unit}" if unit is not None else "—"}],
                title=f"Ordem {o['number']} encerrada")
    return {"order": o["number"], "actual_cost": actual, "components": common.money(comp), "hours_cost": common.money(hours),
            "std_cost": o["std_cost"], "variance": variance, "unit_cost": unit}
