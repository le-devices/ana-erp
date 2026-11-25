# ana:description Portfólio: saúde de todos os projetos (prazo, custo, escopo), margem e alocação
# ana:command portfolio
# ana:category Projetos/Acompanhamento
"""RF-021-10 (diretor). Health from aggregates in SQL (no per-project CPM),
so 500 projects stay well under 2 s (RNF-021-01). Margin only for projects
the user manages or for admins (RNF-021-02)."""

import datetime
from decimal import Decimal

from ana_lib.projects import access
from ana_lib.projects import consulting as C
from ana_lib.projects import finance as F
from ana_lib.projects import views as V

PARAMS = {"status": {"type": "str", "default": "active", "label": "situação", "choices": [["active", "Em execução"], ["proposal", "Propostas"], ["all", "Todos"]]}}


def main(status="active"):
    rows = ana.sql(
        "WITH b AS (SELECT DISTINCT ON (project_id) project_id, id, number FROM projects.baseline "
        "           ORDER BY project_id, number DESC), "
        " bi AS (SELECT b.project_id, sum(i.planned_hours) AS bac, "
        "        sum(i.planned_hours * LEAST(1, GREATEST(0, "
        "          CASE WHEN i.planned_finish IS NULL OR i.planned_start IS NULL THEN 0 "
        "               WHEN i.planned_finish = i.planned_start THEN CASE WHEN current_date >= i.planned_finish THEN 1 ELSE 0 END "
        "               ELSE (current_date - i.planned_start)::numeric / (i.planned_finish - i.planned_start) END))) AS pv "
        "        FROM b JOIN projects.baseline_item i ON i.baseline_id = b.id AND i.kind = 'activity' GROUP BY b.project_id), "
        " t AS (SELECT project_id, sum(planned_hours) AS planned, "
        "       sum(planned_hours * percent_complete / 100) AS ev, "
        "       count(*) FILTER (WHERE status <> 'done' AND planned_finish < current_date) AS late "
        "       FROM projects.task WHERE kind = 'activity' AND active GROUP BY project_id), "
        " h AS (SELECT project_id, sum(hours) FILTER (WHERE status <> 'rejected') AS ac, "
        "       sum(hours * hourly_cost) FILTER (WHERE status IN ('approved', 'invoiced')) AS cost "
        "       FROM projects.time_entry GROUP BY project_id), "
        " f AS (SELECT project_id, sum(total) AS invoiced FROM projects.invoice WHERE status = 'issued' GROUP BY project_id), "
        " sc AS (SELECT project_id, count(*) FILTER (WHERE status NOT IN ('approved', 'rejected')) AS open_changes "
        "        FROM projects.scope_change GROUP BY project_id), "
        " r AS (SELECT project_id, count(*) FILTER (WHERE status <> 'closed' AND probability * impact >= 15) AS high_risks "
        "       FROM projects.risk GROUP BY project_id) "
        "SELECT p.id, p.code, p.name, p.status, p.manager, c.name AS customer, p.due_date, p.budget_hours, "
        "  b.number AS baseline, COALESCE(bi.bac, t.planned, 0) AS bac, bi.pv, COALESCE(t.ev, 0) AS ev, "
        "  COALESCE(h.ac, 0) AS ac, h.cost, COALESCE(f.invoiced, 0) AS invoiced, COALESCE(t.late, 0) AS late, "
        "  COALESCE(sc.open_changes, 0) AS open_changes, COALESCE(r.high_risks, 0) AS high_risks "
        "FROM projects.project p JOIN base.party c ON c.id = p.customer_id "
        "LEFT JOIN b ON b.project_id = p.id LEFT JOIN bi ON bi.project_id = p.id LEFT JOIN t ON t.project_id = p.id "
        "LEFT JOIN h ON h.project_id = p.id LEFT JOIN f ON f.project_id = p.id "
        "LEFT JOIN sc ON sc.project_id = p.id LEFT JOIN r ON r.project_id = p.id "
        "WHERE ($1 = 'all' OR p.status = $1) "
        "  AND ($2 OR p.manager = $3 OR EXISTS (SELECT 1 FROM projects.project_member pm "
        "       JOIN projects.employee e ON e.id = pm.employee_id WHERE pm.project_id = p.id AND e.username = $3)) "
        "ORDER BY p.code", status, access.is_admin(), ana.context.user)
    out, data = [], []
    project_with_forecast = len(rows) <= 100      # RNF-021-01: per-project forecast only for small portfolios
    if not project_with_forecast:
        ana.log("mais de 100 projetos: lucro previsto por projeto disponível na aba Viabilidade de cada um", "info")
    for r in rows:
        spi = (r["ev"] / r["pv"]) if r["pv"] else None
        cpi = (r["ev"] / r["ac"]) if r["ac"] else None
        schedule_ok = r["late"] == 0 and (spi is None or spi >= Decimal("0.9"))
        cost_ok = cpi is None or cpi >= Decimal("0.9")
        scope_ok = r["open_changes"] == 0
        health = "🟢" if schedule_ok and cost_ok and scope_ok and not r["high_risks"] else (
            "🔴" if not schedule_ok and not cost_ok else "🟡")
        margin = (r["invoiced"] - (r["cost"] or 0)) if access.can_manage(r) else None
        forecast = None
        if project_with_forecast and access.can_manage(r):
            res = {k: x for k, _, _, x in F.scenarios(access.project(r["code"]))}
            forecast = {k: res[k]["profit"] for k in ("base", "optimistic", "pessimistic")}
            forecast["margin_pct"] = res["base"]["margin_pct"]
        data.append({**{k: r[k] for k in ("code", "name", "status", "customer", "manager", "due_date")},
                     "spi": C.q2(spi) if spi is not None else None, "cpi": C.q2(cpi) if cpi is not None else None,
                     "late_activities": r["late"], "open_changes": r["open_changes"], "high_risks": r["high_risks"],
                     "margin": margin, "forecast_profit": forecast, "health": health})
        out.append({"": health, "projeto": r["code"], "cliente": r["customer"], "gestor": r["manager"],
                    "prazo": "ok" if schedule_ok else f"atraso ({r['late']} ativ.)",
                    "IDP": C.q2(spi) if spi is not None else "—", "IDC": C.q2(cpi) if cpi is not None else "—",
                    "escopo": "ok" if scope_ok else f"{r['open_changes']} mudança(s) aberta(s)",
                    "riscos altos": r["high_risks"], "margem realizada": V.fmt(margin) if margin is not None else "—",
                    "lucro previsto (pess./base/otim.)": (f"{V.fmt(forecast['pessimistic'])} / {V.fmt(forecast['base'])} / "
                                                          f"{V.fmt(forecast['optimistic'])}") if forecast else "—",
                    "_actions": [{"label": "Abrir", "program": "projects.workspace", "open": True,
                                  "params": {"project": r["code"]}}]})
    ana.metrics([{"label": "Projetos", "value": len(out)},
                 {"label": "Saudáveis", "value": sum(1 for d in data if d["health"] == "🟢"), "status": "ok"},
                 {"label": "Atenção", "value": sum(1 for d in data if d["health"] == "🟡"), "status": "warn"},
                 {"label": "Críticos", "value": sum(1 for d in data if d["health"] == "🔴"), "status": "bad"}],
                title="Portfólio")
    ranked = sorted([d for d in data if d["forecast_profit"]], key=lambda d: -d["forecast_profit"]["base"])[:15]
    if ranked:
        ana.chart(type="bar", title="Lucro previsto por projeto", subtitle="cenário base", format="money",
                  x=[d["code"] for d in ranked], series=[{"name": "Lucro previsto", "values": [d["forecast_profit"]["base"] for d in ranked]}])
    ana.table(out, title="Projetos", empty="Nenhum projeto em andamento no portfólio.",
              empty_action={"label": "Novo projeto", "program": "projects.save_project"})
    team = [r["employee_id"] for r in ana.sql(
        "SELECT DISTINCT pm.employee_id FROM projects.project_member pm JOIN projects.project p ON p.id = pm.project_id "
        "WHERE p.id = ANY($1::int[])", [r["id"] for r in rows])]
    if team:
        V.people(team, V.weeks_from(datetime.date.today(), 4), title="Alocação da equipe nas próximas semanas")
    return data
