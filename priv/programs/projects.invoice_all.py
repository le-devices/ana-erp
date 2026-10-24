# ana:description Fatura todos os projetos ativos com algo a faturar (rotina mensal)
# ana:exposed yes
# ana:role admin
# ana:category Projetos/Faturamento e custos
"""Spec 038 (RF-038-12, phase 4). Every active project with completed milestones, approved billable hours
or rebillable expenses up to `through` is invoiced by projects.invoice_project, each in its own savepoint:
one project that fails (customer without data, contract…) is listed and never stops the others."""

import datetime

PARAMS = {
    "through": {"type": "date", "label": "até a data (vazio = hoje)"},
}


def main(through=None):
    through = through or datetime.date.today()
    codes = [r["code"] for r in ana.sql(
        "SELECT p.code FROM projects.project p WHERE p.status = 'active' AND ("
        " EXISTS (SELECT 1 FROM projects.milestone m WHERE m.project_id = p.id AND m.status = 'completed')"
        " OR EXISTS (SELECT 1 FROM projects.time_entry t WHERE t.project_id = p.id AND t.status = 'approved' AND t.billable "
        "            AND t.invoice_id IS NULL AND t.entry_date <= $1)"
        " OR EXISTS (SELECT 1 FROM projects.expense e WHERE e.project_id = p.id AND e.status = 'posted' AND e.rebillable "
        "            AND e.expense_date <= $1)) ORDER BY p.code", through)]
    invoiced, failed = [], []
    for code in codes:
        try:
            with ana.savepoint():
                r = ana.call("projects.invoice_project", project=code, through=through.isoformat())
            invoiced.append({"projeto": code, "fatura": (r or {}).get("number"), "total": (r or {}).get("total")})
        except ana.Error as e:
            failed.append({"projeto": code, "erro": e.code, "mensagem": e.message})
    if invoiced:
        ana.table(invoiced, title="Projetos faturados")
    if failed:
        ana.table(failed, title="Projetos que não faturaram (verifique)")
    return {"through": through.isoformat(), "invoiced": len(invoiced), "failed": failed}
