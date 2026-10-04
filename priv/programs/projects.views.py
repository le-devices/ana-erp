# ana:description Telas de projeto de consultoria (abas, fluxo guiado, quadro, Gantt, alocação, andamento)
# ana:kind library
"""Spec 021, RF-021-10/11. Each view draws with the rich outputs of the
runtime (metrics, board, gantt, tabs, actions) and returns its data, so the
same views serve the screen and integrations."""

import datetime
from decimal import Decimal

from ana_lib.projects import access
from ana_lib.projects import consulting as C
from ana_lib.projects import finance as F

WORKSPACE = "projects.workspace"
VIEWS = [("overview", "Visão geral"), ("viability", "Viabilidade"), ("structure", "Estrutura"), ("allocation", "Alocação"),
         ("board", "Quadro"), ("gantt", "Linha do tempo"), ("progress", "Andamento"),
         ("changes", "Mudanças"), ("risks", "Riscos"), ("billing", "Faturamento"), ("reports", "Relatórios")]
STATUS = [("todo", "A fazer"), ("doing", "Em andamento"), ("review", "Em revisão"),
          ("done", "Concluído"), ("blocked", "Bloqueado")]
STATUS_LABEL = dict(STATUS)


def fmt(v):
    if v is None:
        return "—"
    if isinstance(v, Decimal):
        return f"{v:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
    if isinstance(v, datetime.date):
        return v.strftime("%d/%m/%Y")
    return v


def open_view(p, view, label=None, **extra):
    return {"label": label or dict(VIEWS)[view], "program": WORKSPACE,
            "params": {"project": p["code"], "view": view, **extra}, "open": True}


# ---------------------------------------------------------------- access

def employee_of(username):
    return ana.sql_one("SELECT id, name, profile FROM projects.employee WHERE username = $1 AND active", username)


def is_member(p):
    return bool(ana.sql_value(
        "SELECT count(*) FROM projects.project_member pm JOIN projects.employee e ON e.id = pm.employee_id "
        "WHERE pm.project_id = $1 AND e.username = $2", p["id"], ana.context.user))


def require_view(p):
    """Manager, admin or team member (RNF-021-02 for cost: see access.can_manage)."""
    if not (access.can_manage(p) or is_member(p)):
        raise ana.Error("FORBIDDEN", f"você não participa do projeto {p['code']}")


def activity(p, code, lock=False):
    t = ana.sql_one("SELECT * FROM projects.task WHERE project_id = $1 AND code = $2 AND active"
                    + (" FOR UPDATE" if lock else ""), p["id"], str(code))
    if not t:
        raise ana.Error("TASK_NOT_FOUND", f"atividade {code} não encontrada no projeto {p['code']}")
    return t


# ---------------------------------------------------------------- guided flow (RF-021-11)

STAGES = [("proposal", "Proposta"), ("approval", "Aprovação do plano"), ("execution", "Execução"),
          ("measurement", "Medições e marcos"), ("billing", "Faturamento"), ("closing", "Encerramento")]


def stage(p):
    counts = ana.sql_one(
        "SELECT count(*) FILTER (WHERE kind = 'activity') AS acts, "
        "  count(*) FILTER (WHERE kind = 'activity' AND status = 'done') AS done "
        "FROM projects.task WHERE project_id = $1 AND active", p["id"])
    has_baseline = bool(ana.sql_value("SELECT count(*) FROM projects.baseline WHERE project_id = $1", p["id"]))
    to_invoice = ana.sql_one(
        "SELECT (SELECT count(*) FROM projects.time_entry WHERE project_id = $1 AND status = 'approved' AND billable) "
        "     + (SELECT count(*) FROM projects.milestone WHERE project_id = $1 AND status = 'completed') AS n, "
        "  (SELECT count(*) FROM projects.time_entry WHERE project_id = $1 AND status = 'pending') AS pending",
        p["id"])
    if p["status"] == "closed":
        return "closing", None
    if counts["acts"] == 0:
        return "proposal", {"label": "Estruturar o projeto (aplicar modelo)", "program": "projects.apply_template",
                            "params": {"project": p["code"]}, "open": True}
    if not has_baseline:
        return "approval", open_view(p, "viability", "Avaliar a viabilidade e aprovar o plano")
    if counts["done"] < counts["acts"]:
        if to_invoice["pending"]:
            return "measurement", {"label": f"Aprovar {to_invoice['pending']} apontamento(s)",
                                   "program": "projects.approve_time", "params": {"project": p["code"]}}
        return "execution", open_view(p, "board", "Acompanhar o quadro")
    if to_invoice["n"]:
        return "billing", {"label": "Faturar o que está aprovado", "program": "projects.invoice_project",
                           "params": {"project": p["code"]}, "open": True}
    return "closing", {"label": "Encerrar o projeto", "program": "projects.save_project",
                       "params": {"code": p["code"], "status": "closed"}, "confirm": "Encerrar o projeto?"}


# ---------------------------------------------------------------- views

def header(p, view):
    manage = access.can_manage(p)
    ana.tabs([open_view(p, v) for v, _ in VIEWS if manage or v != "viability"], current=view)


def overview(p):
    current, nxt = stage(p)
    names = dict(STAGES)
    passed = True
    flow = []
    for key, label in STAGES:
        if key == current:
            flow.append(f"▶ {label}")
            passed = False
        else:
            flow.append(("✓ " if passed else "· ") + label)
    prog = C.progress(p)
    sched = C.schedule(p)
    t = prog["project"]
    ana.metrics([
        {"label": "Etapa", "value": names[current], "hint": "  →  ".join(flow)},
        {"label": "% concluído", "value": f"{t['percent_complete']}%",
         "hint": f"{t['ev_hours']} h agregadas de {t['bac_hours']} h"},
        {"label": "Horas apontadas", "value": f"{t['ac_hours']} h", "hint": f"{t['hours_consumed_pct']}% do planejado",
         "status": "bad" if t["cpi"] is not None and t["cpi"] < Decimal("0.9") else None},
        {"label": "IDP / IDC", "value": f"{t['spi'] or '—'} / {t['cpi'] or '—'}",
         "status": "warn" if t["alerts"] else "ok"},
        {"label": "Término previsto", "value": fmt(sched["finish"]),
         "hint": f"prazo {fmt(p['due_date'])}",
         "status": "bad" if p["due_date"] and sched["finish"] > p["due_date"] else "ok"},
    ], title=f"{p['code']} — {p['name']}")
    if access.can_manage(p):
        res = {k: r for k, _, _, r in F.scenarios(p)}
        b, o, w = res["base"], res["optimistic"], res["pessimistic"]
        ana.metrics([{"label": "Lucro previsto (base)", "value": fmt(b["profit"]),
                      "hint": f"margem {b['margin_pct'] if b['margin_pct'] is not None else '—'}%",
                      "status": F.VERDICT[b["verdict"]][1]},
                     {"label": "Otimista", "value": fmt(o["profit"])},
                     {"label": "Pessimista", "value": fmt(w["profit"]), "status": "bad" if w["profit"] < 0 else None},
                     {"label": "Faturamento previsto", "value": fmt(b["revenue"])}],
                    title="Resultado previsto (alocação + realizado)" if b["executing"] else "Projeção da proposta")
    if nxt:
        ana.actions([nxt], title="Próximo passo")
    for a in t["alerts"]:
        ana.log(a, "warning")
    return {"stage": current, "next": nxt, "progress": t, "forecast_finish": sched["finish"]}


def structure(p):
    tasks, deps = C.load_plan(p["id"])
    sched = C.schedule(p, tasks, deps)
    by_id = {t["id"]: t for t in tasks}
    preds = {}
    for d in deps:
        if d["predecessor_id"] in by_id:
            lag = f"+{d['lag_days']}" if d["lag_days"] else ""
            preds.setdefault(d["task_id"], []).append(by_id[d["predecessor_id"]]["code"] + lag)
    manage = access.can_manage(p)
    rows = []
    for t in ordered(tasks):
        s = sched["items"].get(t["id"], {})
        row = {"código": t["code"], "fase/atividade": ("   " if t["parent_id"] else "") + t["name"],
               "responsável": t["owner_name"] or (t["profile"] or ""), "horas": t["planned_hours"],
               "dias úteis": t["duration_days"], "predecessoras": ", ".join(preds.get(t["id"], [])),
               "início": fmt(s.get("es")), "término": fmt(s.get("ef")),
               "situação": STATUS_LABEL.get(t["status"]) if t["kind"] == "activity" else "",
               "%": t["percent_complete"] if t["kind"] == "activity" else "",
               "entregável": t["deliverable"] or ""}
        acts = []
        if t["kind"] == "activity":
            acts.append(open_view(p, "activity", "Detalhe", activity=t["code"]))
        if manage:
            acts.append({"label": "Editar", "program": "projects.save_activity", "open": True,
                         "params": {"project": p["code"], "code": t["code"]}})
        row["_actions"] = acts
        rows.append(row)
    ana.table(rows, title="Estrutura analítica")
    if manage:
        ana.actions([
            {"label": "+ Fase ou atividade", "program": "projects.save_activity", "open": True,
             "params": {"project": p["code"]}},
            {"label": "Aplicar modelo", "program": "projects.apply_template", "open": True,
             "params": {"project": p["code"]}},
        ])
    return rows


def ordered(tasks):
    """Phases in order, each followed by its activities; loose activities at the end."""
    out = []
    phases = [t for t in tasks if t["kind"] == "phase"]
    for ph in phases:
        out.append(ph)
        out.extend(t for t in tasks if t["parent_id"] == ph["id"])
    out.extend(t for t in tasks if t["kind"] == "activity" and t["parent_id"] is None)
    return out


def board(p):
    tasks, deps = C.load_plan(p["id"])
    sched = C.schedule(p, tasks, deps)
    phases = {t["id"]: t["name"] for t in tasks if t["kind"] == "phase"}
    cards = []
    for t in tasks:
        if t["kind"] != "activity":
            continue
        s = sched["items"][t["id"]]
        badges = [f"{t['percent_complete']:.0f}%", f"até {fmt(s['ef'])}"]
        if s["critical"]:
            badges.append("crítica")
        if s["late"]:
            badges.append("atrasada")
        moves = [{"label": label, "program": "projects.update_progress",
                  "params": {"project": p["code"], "activity": t["code"], "status": key}}
                 for key, label in STATUS if key != t["status"] and key != "blocked"][:2]
        cards.append({"column": t["status"], "title": f"{t['code']} {t['name']}",
                      "subtitle": " · ".join(x for x in (phases.get(t["parent_id"]), t["owner_name"]) if x),
                      "badges": badges, "status": "late" if s["late"] else ("critical" if s["critical"] else None),
                      "actions": moves + [{"label": "Andamento", "program": "projects.update_progress",
                                           "params": {"project": p["code"], "activity": t["code"]},
                                           "ask": {"percent": {"type": "decimal", "label": "% concluído"},
                                                   "note": {"type": "str", "label": "observação"}}}]})
    ana.board([{"key": k, "label": label} for k, label in STATUS], cards, title="Fluxo do trabalho")
    return cards


def gantt(p):
    tasks, deps = C.load_plan(p["id"])
    sched = C.schedule(p, tasks, deps)
    base = C.latest_baseline(p["id"])
    bitems = {}
    if base:
        bitems = {b["task_id"]: b for b in ana.sql("SELECT * FROM projects.baseline_item WHERE baseline_id = $1",
                                                   base["id"])}
    items = []
    for t in ordered(tasks):
        s = sched["items"].get(t["id"])
        if not s:
            continue
        b = bitems.get(t["id"])
        items.append({"code": t["code"], "name": t["name"], "kind": t["kind"], "level": 1 if t["parent_id"] else 0,
                      "start": s["es"], "finish": s["ef"], "critical": s["critical"],
                      "float": s.get("float"), "progress": t["percent_complete"],
                      "baseline_start": b and b["planned_start"], "baseline_finish": b and b["planned_finish"]})
    ana.gantt(items, title=f"Linha do tempo — término previsto {fmt(sched['finish'])}", today=datetime.date.today())
    return {"finish": sched["finish"], "items": items}


def progress(p):
    prog = C.progress(p)
    rows = [{"fase": f"{r['code']} {r['name']}", "h planejadas": r["bac_hours"], "h previstas até hoje (VP)": r["pv_hours"],
             "h agregadas (VA)": r["ev_hours"], "h apontadas (CR)": r["ac_hours"], "% concluído": r["percent_complete"],
             "% horas consumidas": r["hours_consumed_pct"], "IDP": r["spi"], "IDC": r["cpi"],
             "estimativa no término (h)": r["eac_hours"], "alertas": "; ".join(r["alerts"])}
            for r in prog["phases"] + [prog["project"]]]
    ana.table(rows, title="Planejado × realizado" + (f" (linha de base {prog['baseline']['number']})"
                                                     if prog["baseline"] else " (sem linha de base)"))
    if access.can_manage(p):
        cost = ana.sql_value(
            "SELECT COALESCE(sum(t.hours * COALESCE(t.hourly_cost, e.hourly_cost)), 0) FROM projects.time_entry t "
            "JOIN projects.employee e ON e.id = t.employee_id WHERE t.project_id = $1 AND t.status <> 'rejected'",
            p["id"])
        ana.metrics([{"label": "Valor planejado", "value": fmt(prog["project"]["bac_value"])},
                     {"label": "Valor agregado", "value": fmt(prog["project"]["ev_value"])},
                     {"label": "Custo realizado", "value": fmt(C.q2(cost)), "hint": "visível só para o gestor"}])
    ana.actions([open_view(p, "gantt", "Ver linha do tempo"),
                 {"label": "Comparar linhas de base", "program": "projects.baselines", "open": True,
                  "params": {"project": p["code"]}}])
    return prog


def weeks_from(start, n):
    m = C.monday(start)
    return [m + datetime.timedelta(weeks=k) for k in range(n)]


def allocation(p, weeks=6, start=None):
    start = start or datetime.date.today()
    ws = weeks_from(start, weeks)
    rows = ana.sql(
        "SELECT a.week, a.hours, a.employee_id, a.profile, e.name AS employee, t.code, t.name AS task "
        "FROM projects.allocation a JOIN projects.task t ON t.id = a.task_id "
        "LEFT JOIN projects.employee e ON e.id = a.employee_id "
        "WHERE a.project_id = $1 AND a.week = ANY($2::date[]) ORDER BY t.seq, t.code", p["id"], ws)
    grid = {}
    for r in rows:
        key = (r["code"], r["task"], r["employee"] or f"perfil {r['profile']}")
        grid.setdefault(key, {})[r["week"]] = r["hours"]
    table = []
    for (code, task, who), cells in grid.items():
        row = {"atividade": f"{code} {task}", "pessoa": who}
        for w in ws:
            row[w.strftime("%d/%m")] = cells.get(w, "")
        table.append(row)
    ana.table(table, title="Alocação do projeto (horas por semana)")
    team = [r["employee_id"] for r in ana.sql("SELECT employee_id FROM projects.project_member WHERE project_id = $1",
                                              p["id"])]
    people(team, ws, title="Equipe: carga em todos os projetos")
    if access.can_manage(p):
        ana.actions([{"label": "Alocar pessoa", "program": "projects.allocate", "open": True,
                      "params": {"project": p["code"]}},
                     {"label": "Quadro de alocação geral", "program": "projects.allocation_board", "open": True,
                      "params": {}}])
    return table


def people(employees, ws, title):
    """People × weeks: allocated / capacity in all projects, with overallocation marked."""
    if not employees:
        ana.log("nenhuma pessoa na equipe", "warning")
        return []
    cap = C.week_capacity(employees, ws)
    alloc = C.allocated(employees, ws)
    names = {r["id"]: r["name"] for r in ana.sql("SELECT id, name FROM projects.employee WHERE id = ANY($1::int[])",
                                                 list(employees))}
    out, over = [], []
    for e in sorted(employees, key=lambda x: names.get(x, "")):
        row = {"pessoa": names.get(e, e)}
        for w in ws:
            a, c = alloc.get((e, w), Decimal(0)), cap[(e, w)]
            mark = " ⚠" if a > c else ""
            row[w.strftime("%d/%m")] = f"{fmt(a)}/{fmt(c)}{mark}"
            if a > c:
                over.append({"employee_id": e, "pessoa": names.get(e), "week": w, "excess": a - c})
        out.append(row)
    ana.table(out, title=title + " (alocado/capacidade)")
    for o in over:
        sug = C.suggest_moves(o["employee_id"], o["week"], o["excess"])
        hint = ", ".join(f"{fmt(s['hours'])} h em {fmt(s['week'])}" for s in sug) or "sem folga nas próximas semanas"
        ana.log(f"{o['pessoa']} sobrealocado(a) em {fmt(o['excess'])} h na semana de {fmt(o['week'])}; "
                f"sugestão: mover {hint}", "warning")
    return over


def activity_detail(p, code):
    t = activity(p, code)
    s = C.schedule(p)["items"].get(t["id"], {})
    rows = ana.sql(
        "WITH al AS (SELECT employee_id, profile, sum(hours) AS allocated FROM projects.allocation "
        "            WHERE task_id = $1 GROUP BY 1, 2), "
        "     lg AS (SELECT employee_id, sum(hours) AS logged FROM projects.time_entry "
        "            WHERE task_id = $1 AND status <> 'rejected' GROUP BY 1) "
        "SELECT COALESCE(e.name, 'perfil ' || al.profile, e2.name) AS who, al.allocated, lg.logged "
        "FROM al FULL JOIN lg ON lg.employee_id = al.employee_id "
        "LEFT JOIN projects.employee e ON e.id = al.employee_id "
        "LEFT JOIN projects.employee e2 ON e2.id = lg.employee_id ORDER BY 1", t["id"])
    ana.metrics([{"label": "Situação", "value": STATUS_LABEL.get(t["status"]), "hint": f"{t['percent_complete']}% concluído"},
                 {"label": "Planejado", "value": f"{fmt(t['planned_hours'] or 0)} h"},
                 {"label": "Alocado", "value": f"{fmt(sum((r['allocated'] or 0) for r in rows))} h"},
                 {"label": "Apontado", "value": f"{fmt(sum((r['logged'] or 0) for r in rows))} h"},
                 {"label": "Previsto", "value": f"{fmt(s.get('es'))} → {fmt(s.get('ef'))}",
                  "hint": f"folga {s.get('float', '—')} dia(s) útil(eis)" + (" · crítica" if s.get("critical") else ""),
                  "status": "warn" if s.get("critical") else None}],
                title=f"{t['code']} {t['name']}")
    ana.table([{"pessoa": r["who"], "alocado (h)": r["allocated"] or 0, "apontado (h)": r["logged"] or 0}
               for r in rows], title="Planejado × alocado × apontado por pessoa")
    acts = [open_view(p, "structure", "Voltar à estrutura")]
    if access.can_manage(p):
        acts.insert(0, {"label": "Alocar pessoa", "program": "projects.allocate", "open": True,
                        "params": {"project": p["code"], "activity": t["code"]}})
    ana.actions(acts)
    return {"activity": t["code"], "people": rows}


def changes(p):
    rows = ana.sql("SELECT * FROM projects.scope_change WHERE project_id = $1 ORDER BY number DESC", p["id"])
    labels = {"requested": "pedida", "estimated": "estimada", "approved_internal": "aprovada internamente",
              "approved": "aprovada pelo cliente", "rejected": "recusada"}
    out = []
    for r in rows:
        acts = []
        if access.can_manage(p) and r["status"] not in ("approved", "rejected"):
            if r["status"] == "requested":
                acts.append({"label": "Estimar", "program": "projects.scope_change",
                             "params": {"project": p["code"], "number": r["number"], "action": "estimate"},
                             "ask": {"est_hours": {"type": "decimal", "label": "horas", "required": True},
                                     "est_amount": {"type": "decimal", "label": "valor"},
                                     "est_days": {"type": "int", "label": "dias de prazo"}}})
            if r["status"] == "estimated":
                acts.append({"label": "Aprovar internamente", "program": "projects.scope_change",
                             "params": {"project": p["code"], "number": r["number"], "action": "approve_internal"}})
            if r["status"] == "approved_internal":
                acts.append({"label": "Registrar aprovação do cliente", "program": "projects.scope_change",
                             "params": {"project": p["code"], "number": r["number"], "action": "approve_customer"},
                             "ask": {"customer_approver": {"type": "str", "label": "aprovado por (cliente)",
                                                           "required": True}}})
            acts.append({"label": "Recusar", "program": "projects.scope_change",
                         "params": {"project": p["code"], "number": r["number"], "action": "reject"},
                         "ask": {"reason": {"type": "str", "label": "motivo", "required": True}}})
        out.append({"nº": r["number"], "mudança": r["title"], "situação": labels[r["status"]],
                    "horas": r["est_hours"], "valor": fmt(r["est_amount"]) if r["est_amount"] is not None else "—",
                    "dias": r["est_days"], "pedida por": r["requested_by"], "_actions": acts})
    ana.table(out, title="Mudanças de escopo")
    ana.actions([{"label": "+ Pedido de mudança", "program": "projects.scope_change",
                  "params": {"project": p["code"], "action": "request"},
                  "ask": {"title": {"type": "str", "label": "título", "required": True},
                          "description": {"type": "str", "label": "descrição"}}}])
    return out


def risks(p):
    rows = ana.sql("SELECT * FROM projects.risk WHERE project_id = $1 ORDER BY status = 'closed', "
                   "probability * impact DESC, id", p["id"])
    labels = {"open": "aberto", "mitigating": "em tratamento", "closed": "fechado"}
    out = [{"tipo": "risco" if r["kind"] == "risk" else "pendência", "título": r["title"],
            "exposição": r["probability"] * r["impact"], "dono": r["owner"] or "", "plano": r["action_plan"],
            "prazo": fmt(r["due_date"]), "situação": labels[r["status"]],
            "visível ao cliente": "sim" if r["client_visible"] else "não",
            "_actions": [] if r["status"] == "closed" else
            [{"label": "Fechar", "program": "projects.save_risk",
              "params": {"project": p["code"], "id": r["id"], "status": "closed"}}]} for r in rows]
    ana.table(out, title="Riscos e pendências")
    ana.actions([{"label": "+ Risco ou pendência", "program": "projects.save_risk",
                  "params": {"project": p["code"]},
                  "ask": {"title": {"type": "str", "label": "título", "required": True},
                          "kind": {"type": "str", "label": "risk ou issue", "default": "risk"},
                          "probability": {"type": "int", "label": "probabilidade 1–5", "default": 3},
                          "impact": {"type": "int", "label": "impacto 1–5", "default": 3},
                          "owner": {"type": "str", "label": "dono"},
                          "action_plan": {"type": "str", "label": "plano de ação"},
                          "due_date": {"type": "date", "label": "prazo"},
                          "client_visible": {"type": "bool", "label": "visível ao cliente"}}}])
    return out


def billing(p):
    ms = ana.sql("SELECT description, amount, due_date, status FROM projects.milestone WHERE project_id = $1 "
                 "ORDER BY due_date NULLS LAST, id", p["id"])
    labels = {"planned": "previsto", "completed": "concluído", "invoiced": "faturado"}
    ana.table([{"marco": m["description"], "valor": fmt(m["amount"]), "data": fmt(m["due_date"]),
                "situação": labels[m["status"]]} for m in ms], title="Marcos")
    hours = ana.sql_one(
        "SELECT COALESCE(sum(hours) FILTER (WHERE status = 'pending'), 0) AS pending, "
        "  COALESCE(sum(hours) FILTER (WHERE status = 'approved' AND billable), 0) AS approved "
        "FROM projects.time_entry WHERE project_id = $1", p["id"])
    ana.metrics([{"label": "Horas a aprovar", "value": f"{fmt(hours['pending'])} h"},
                 {"label": "Horas aprovadas a faturar", "value": f"{fmt(hours['approved'])} h"}])
    if access.can_manage(p):
        ana.actions([{"label": "Aprovar apontamentos", "program": "projects.approve_time",
                      "params": {"project": p["code"]}},
                     {"label": "Faturar", "program": "projects.invoice_project", "open": True,
                      "params": {"project": p["code"]}}])
    return {"milestones": ms, "hours": hours}


def reports(p):
    rows = ana.sql("SELECT id, period_start, period_end, client_visible, created_by, created_at, content "
                   "FROM projects.status_report WHERE project_id = $1 ORDER BY period_end DESC, id DESC LIMIT 20",
                   p["id"])
    ana.table([{"período": f"{fmt(r['period_start'])} a {fmt(r['period_end'])}",
                "% concluído": r["content"].get("percent_complete"),
                "visível ao cliente": "sim" if r["client_visible"] else "não", "gerado por": r["created_by"]}
               for r in rows], title="Relatórios de status")
    ana.actions([{"label": "Gerar relatório agora", "program": "projects.status_report",
                  "params": {"project": p["code"]}}])
    return rows


# ---------------------------------------------------------------- viability

def viability(p, simulation=None):
    """RF-021-12..15: base, optimistic and pessimistic always side by side (manager only)."""
    access.require_manager(p)
    results = F.scenarios(p, simulation)
    base = results[0][3]
    label, status = F.VERDICT[base["verdict"]]
    pes = next(r[3] for r in results if r[0] == "pessimistic")
    pol = base["policy"]
    ana.metrics([
        {"label": "Viabilidade (base)", "value": label, "status": status,
         "hint": f"margem alvo {pol['target_margin_pct']}% · mínima {pol['min_margin_pct']}%"},
        {"label": "Faturamento", "value": fmt(base["revenue"]), "hint": f"impostos {fmt(base['taxes'])}"},
        {"label": "Custo", "value": fmt(base["cost"]),
         "hint": f"pessoal {fmt(base['labor_cost'])} · despesas {fmt(base['expense_cost'])} · gerais {fmt(base['overhead'])}"},
        {"label": "Lucro", "value": fmt(base["profit"]),
         "hint": f"margem {base['margin_pct'] if base['margin_pct'] is not None else '—'}%", "status": status},
        {"label": "Resultado acumulado positivo", "value": fmt(base["payback_month"]) if base["payback_month"] else "nunca",
         "status": "bad" if not base["payback_month"] else None},
    ], title=f"Viabilidade {p['code']} — " + ("previsão no término (realizado + restante)" if base["executing"]
                                               else "projeção da proposta"))
    if pes["profit"] < 0:
        ana.log(f"no cenário pessimista o projeto dá prejuízo de {fmt(-pes['profit'])}", "warning")
    for w in base["warnings"]:
        ana.log(w, "warning")
    rows = []
    for key, name, adj, r in results:
        vl, _ = F.VERDICT[r["verdict"]]
        rows.append({"cenário": name, "premissas": F.describe(adj), "horas": r["hours"],
                     "faturamento": fmt(r["revenue"]), "custo": fmt(r["cost"]), "lucro": fmt(r["profit"]),
                     "margem %": r["margin_pct"] if r["margin_pct"] is not None else "—",
                     "término": fmt(r["finish"]), "viabilidade": vl,
                     "_actions": [] if not key.startswith("custom:") else
                     [{"label": "Excluir", "program": "projects.save_scenario",
                       "params": {"project": p["code"], "name": name, "remove": True}}]})
    ana.table(rows, title="Cenários")
    ana.table([{"mês": m["month"].strftime("%m/%Y"), "faturamento": fmt(m["revenue"]), "impostos": fmt(m["taxes"]),
                "custo": fmt(m["cost"]), "resultado": fmt(m["result"]), "acumulado": fmt(m["cumulative"])}
               for m in base["monthly"]], title="Mês a mês (cenário base)")
    ana.table([{"pessoa/perfil": x["who"], "horas": x["hours"], "custo": fmt(x["cost"]),
                "faturamento": fmt(x["revenue"])} for x in base["people"]], title="Por pessoa (alocação)")
    acts = [
        {"label": "Salvar cenário", "program": "projects.save_scenario", "params": {"project": p["code"]},
         "ask": {"name": {"type": "str", "label": "nome", "required": True},
                 "rate_pct": {"type": "decimal", "label": "valor-hora (%)"},
                 "hours_pct": {"type": "decimal", "label": "horas (%)"},
                 "cost_pct": {"type": "decimal", "label": "custo (%)"},
                 "delay_weeks": {"type": "int", "label": "atraso (semanas)"}}},
        {"label": "Despesa prevista", "program": "projects.save_planned_expense", "params": {"project": p["code"]},
         "ask": {"description": {"type": "str", "label": "descrição", "required": True},
                 "amount": {"type": "decimal", "label": "valor", "required": True},
                 "monthly": {"type": "bool", "label": "mensal"},
                 "expected_date": {"type": "date", "label": "data prevista"},
                 "rebillable": {"type": "bool", "label": "repassar ao cliente"},
                 "markup_pct": {"type": "decimal", "label": "acréscimo no repasse (%)"}}},
        {"label": "Ajustar valores-hora e orçamento", "program": "projects.save_project", "open": True,
         "params": {"code": p["code"]}},
        open_view(p, "allocation", "Ajustar alocação"),
        open_view(p, "structure", "Ajustar prazos e atividades"),
    ]
    if p["status"] == "proposal" or not ana.sql_value("SELECT count(*) FROM projects.baseline WHERE project_id = $1",
                                                      p["id"]):
        acts.append({"label": "Aprovar o plano", "program": "projects.approve_plan", "params": {"project": p["code"]},
                     "ask": {"reason": {"type": "str", "label": "observação"},
                             "low_margin_justification": {"type": "str", "label": "justificativa (se margem abaixo da mínima)"}}})
    ana.actions(acts, title="Corrigir antes de executar")
    return {"scenarios": [{"key": k, "name": n, "adjustments": a, **{x: r[x] for x in
            ("revenue", "taxes", "cost", "labor_cost", "expense_cost", "profit", "margin_pct", "verdict", "finish",
              "hours", "payback_month")}}
            for k, n, a, r in results],
            "base": base}
