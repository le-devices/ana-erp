# ana:description Bancada de produção: ordens em aberto, sugestões do planejamento e próximos passos
# ana:command producao
# ana:category Produção/Planejamento
"""Production workbench (H4–H6): each order shows the next step on its own row."""

import datetime
from ana_lib.docs.common import link as doc_link

PARAMS = {}
STATUS = {"planned": "planejada", "released": "liberada", "in_progress": "em andamento", "completed": "concluída"}


def main():
    today = datetime.date.today()
    c = ana.sql_one(
        "SELECT count(*) FILTER (WHERE status = 'planned') AS planned, count(*) FILTER (WHERE status IN ('released', 'in_progress')) AS running, "
        "  count(*) FILTER (WHERE status = 'completed') AS to_close, "
        "  count(*) FILTER (WHERE status IN ('planned', 'released', 'in_progress') AND due_date < $1) AS late, "
        "  (SELECT count(*) FROM production.suggestion WHERE status = 'open') AS suggestions "
        "FROM production.work_order WHERE status NOT IN ('closed', 'cancelled')", today)
    ana.metrics([{"label": "Planejadas", "value": c["planned"]}, {"label": "Em produção", "value": c["running"]},
                 {"label": "A encerrar", "value": c["to_close"], "status": "warn" if c["to_close"] else "ok"},
                 {"label": "Atrasadas", "value": c["late"], "status": "bad" if c["late"] else "ok"},
                 {"label": "Sugestões abertas", "value": c["suggestions"]}])
    rows = ana.sql("SELECT w.number, p.code, p.description, w.quantity, w.good_qty, w.start_date, w.due_date, w.status, "
                   "  pj.code AS project FROM production.work_order w JOIN base.product p ON p.id = w.product_id "
                   "LEFT JOIN projects.project pj ON pj.id = w.project_id "
                   "WHERE w.status NOT IN ('closed', 'cancelled') ORDER BY w.due_date, w.number LIMIT 300")

    def step(r):
        n = {"order": r["number"]}
        if r["status"] == "planned":
            return [{"label": "Liberar", "program": "production.release_order", "params": n, "style": "primary"}]
        if r["status"] in ("released", "in_progress"):
            return [{"label": "Requisitar", "program": "production.issue_components", "params": n},
                    {"label": "Apontar", "program": "production.report_operation", "params": n,
                     "ask": {"seq": {"type": "int", "label": "operação", "required": True},
                             "hours": {"type": "decimal", "label": "horas", "required": True},
                             "good_qty": {"type": "decimal", "label": "boas"}}},
                    {"label": "Entregar", "program": "production.deliver", "params": n, "style": "primary",
                     "ask": {"good_qty": {"type": "decimal", "label": "boas", "required": True},
                             "scrap_qty": {"type": "decimal", "label": "refugo"}}}]
        return [{"label": "Encerrar", "program": "production.close_order", "params": n, "style": "primary"}]
    ana.table([{"ordem": r["number"], "_open": doc_link("work_order", r["number"]), "item": f"{r['code']} — {r['description']}", "quantidade": r["quantity"],
                "boas": r["good_qty"], "início": r["start_date"], "término": r["due_date"],
                "situação": STATUS[r["status"]] + (" (atrasada)" if r["due_date"] < today and r["status"] != "completed" else ""),
                "projeto": r["project"], "_actions": step(r)} for r in rows], title="Ordens de produção em aberto",
              empty="Nenhuma ordem de produção em aberto.", empty_action={"label": "Nova ordem de produção", "program": "production.create_order"})
    ana.actions([{"label": "Planejar necessidades", "program": "production.plan", "open": True},
                 {"label": "Carga × capacidade", "program": "production.capacity_load", "open": True},
                 {"label": "Capacidade de serviços", "program": "production.service_capacity", "open": True},
                 {"label": "Nova ordem", "program": "production.create_order", "open": True}], title="Outras tarefas")
    return {"counts": c}
