# ana:description Meus projetos: andamento, marcos, próximos passos e riscos (portal do cliente)
# ana:portal yes
# ana:command meusprojetos
"""Spec 021 (H8, RF-021-09, CA-021-07) on the portal of spec 016: the customer's projects with
the latest status report marked visible to the customer. Never costs, rates or margin
(RNF-021-02): only what the status report stores, which is client-safe by construction."""

PARAMS = {"customer": {"type": "int", "label": "cliente (só para usuários internos)"}}


def main(customer=None):
    party = ana.context.party or customer
    if not party:
        raise ana.Error("INVALID_PARAMETER", "informe o cliente")
    if ana.context.party and customer and int(customer) != int(ana.context.party):
        raise ana.Error("FORBIDDEN", "a conta do portal só vê os próprios projetos")
    rows = ana.sql(
        "SELECT p.code, p.name, p.status, p.due_date, r.period_end, r.content "
        "FROM projects.project p LEFT JOIN LATERAL (SELECT period_end, content FROM projects.status_report s "
        "  WHERE s.project_id = p.id AND s.client_visible ORDER BY s.period_end DESC, s.id DESC LIMIT 1) r ON true "
        "WHERE p.customer_id = $1 AND p.status <> 'proposal' ORDER BY p.code LIMIT 100", int(party))
    labels = {"active": "em andamento", "paused": "pausado", "closed": "encerrado"}
    ana.table([{"projeto": f"{r['code']} — {r['name']}", "situação": labels.get(r["status"], r["status"]),
                "% concluído": (r["content"] or {}).get("percent_complete"),
                "término previsto": (r["content"] or {}).get("forecast_finish"), "prazo": r["due_date"],
                "relatório de": r["period_end"]} for r in rows], title="Projetos")
    out = []
    for r in rows:
        c = r["content"]
        if not c:
            continue
        ana.table([{"marco": m["description"], "previsto": m["due_date"], "situação": m["status"]} for m in c["milestones"]],
                  title=f"{r['code']}: marcos")
        ana.table([{"próximo passo": f"{s['code']} {s['name']}", "de": s["start"], "até": s["finish"]} for s in c["next_steps"]],
                  title=f"{r['code']}: próximos passos")
        if c["risks"]:
            ana.table([{"tipo": "risco" if x["kind"] == "risk" else "pendência", "título": x["title"],
                        "plano de ação": x["action_plan"], "prazo": x["due_date"]} for x in c["risks"]],
                      title=f"{r['code']}: riscos e pendências")
        out.append({"project": r["code"], "report": c})
    return {"projects": [r["code"] for r in rows], "reports": out}
