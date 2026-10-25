# ana:description Orçamento: meses do intervalo, escopo (centros com os filhos, conta), linhas da grade e versão
# ana:kind library
"""Shared by finance.budget_plan and finance.save_budget_plan (spec 027 RF-027-05, spec 020 RF-020-15)."""

import datetime

import ana

STATUSES = [["draft", "Rascunho"], ["review", "Em revisão"], ["approved", "Aprovado"]]
MONTHS = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]
MAX_MONTHS = 36


def months(start, end):
    try:
        a = datetime.date.fromisoformat(str(start)[:7] + "-01")
        b = datetime.date.fromisoformat(str(end)[:7] + "-01")
    except ValueError:
        raise ana.Error("INVALID_PARAMETER", "meses no formato AAAA-MM") from None
    if b < a:
        raise ana.Error("INVALID_PARAMETER", "o mês final vem antes do inicial")
    out = []
    while a <= b:
        out.append(a)
        a = (a.replace(day=28) + datetime.timedelta(days=4)).replace(day=1)
        if len(out) > MAX_MONTHS:
            raise ana.Error("INVALID_PARAMETER", f"no máximo {MAX_MONTHS} meses na grade")
    return out


def label(m):
    return f"{MONTHS[m.month - 1]}/{str(m.year)[2:]}"


def scope(ms, cost_center=None, account=None):
    centers = None
    if cost_center:
        centers = [r["code"] for r in ana.sql(
            "WITH RECURSIVE t AS (SELECT code FROM finance.cost_center WHERE code = $1 "
            "  UNION SELECT c.code FROM finance.cost_center c JOIN t ON c.parent_code = t.code) SELECT code FROM t",
            cost_center.upper())]
        if not centers:
            raise ana.Error("INVALID_PARAMETER", f"centro de custo {cost_center} inexistente")
    return {"start": ms[0], "end": ms[-1], "months": ms, "centers": centers, "account": (account or "").strip() or None}


_WHERE = ("($3::text[] IS NULL OR x.cost_center = ANY($3)) AND ($4::text IS NULL OR x.account LIKE $4 || '%')")


def version(sc):
    """Token of everything the grid shows in this scope: amounts, situations and comments."""
    return ana.sql_value(
        "SELECT md5(COALESCE(string_agg(t, '|' ORDER BY t), '')) FROM ("
        " SELECT concat_ws(';', x.cost_center, x.account, x.month, x.amount) AS t FROM finance.cost_center_budget x "
        " WHERE x.month BETWEEN $1 AND $2 AND " + _WHERE +
        " UNION ALL SELECT concat_ws(';', x.cost_center, x.account, x.status, x.comment) FROM finance.cost_center_budget_line x "
        " WHERE $1 IS NOT NULL AND $2 IS NOT NULL AND " + _WHERE + ") v",
        sc["start"], sc["end"], sc["centers"], sc["account"])


def rows(sc):
    """Grid rows: every cost center × account budgeted in the interval (or with a situation), with the realized
    amount per month (revenue: credit − debit; expense: debit − credit)."""
    p = (sc["start"], sc["end"], sc["centers"], sc["account"])
    lines = ana.sql(
        "SELECT x.cost_center, x.account FROM finance.cost_center_budget x WHERE x.month BETWEEN $1 AND $2 AND " + _WHERE +
        " UNION SELECT x.cost_center, x.account FROM finance.cost_center_budget_line x WHERE $1 IS NOT NULL AND $2 IS NOT NULL AND "
        + _WHERE + " ORDER BY 1, 2 LIMIT 2000", *p)
    if not lines:
        return []
    ccs = sorted({l["cost_center"] for l in lines})
    accs = sorted({l["account"] for l in lines})
    planned = ana.sql("SELECT cost_center, account, to_char(month, 'YYYY-MM') AS m, amount FROM finance.cost_center_budget "
                      "WHERE month BETWEEN $1 AND $2 AND cost_center = ANY($3) AND account = ANY($4)", sc["start"], sc["end"], ccs, accs)
    real = ana.sql(
        "SELECT l.cost_center, l.account, to_char(date_trunc('month', e.entry_date), 'YYYY-MM') AS m, "
        "  sum(CASE WHEN a.nature = 'revenue' THEN l.credit - l.debit ELSE l.debit - l.credit END) AS amount "
        "FROM finance.journal_line l JOIN finance.journal_entry e ON e.id = l.entry_id JOIN finance.account a ON a.code = l.account "
        "WHERE e.entry_date >= $1 AND e.entry_date < ($2::date + interval '1 month') AND l.cost_center = ANY($3) AND l.account = ANY($4) "
        "GROUP BY 1, 2, 3", sc["start"], sc["end"], ccs, accs)
    info = {(r["cost_center"], r["account"]): r for r in ana.sql(
        "SELECT cost_center, account, status, comment FROM finance.cost_center_budget_line WHERE cost_center = ANY($1) AND account = ANY($2)",
        ccs, accs)}
    names = {r["code"]: r["name"] for r in ana.sql("SELECT code, name FROM finance.cost_center WHERE code = ANY($1)", ccs)}
    descs = {r["code"]: r["description"] for r in ana.sql("SELECT code, description FROM finance.account WHERE code = ANY($1)", accs)}
    by = {}
    for r in planned:
        by.setdefault((r["cost_center"], r["account"]), {"values": {}, "consumed": {}})["values"][r["m"]] = r["amount"]
    for r in real:
        by.setdefault((r["cost_center"], r["account"]), {"values": {}, "consumed": {}})["consumed"][r["m"]] = r["amount"]
    out = []
    for l in lines:
        k = (l["cost_center"], l["account"])
        d = by.get(k, {"values": {}, "consumed": {}})
        i = info.get(k, {})
        out.append({"key": {"cost_center": k[0], "account": k[1]},
                    "labels": {"cost_center": f"{k[0]} {names.get(k[0], '')}".strip(), "account": f"{k[1]} {descs.get(k[1], '')}".strip()},
                    "values": d["values"], "consumed": d["consumed"], "status": i.get("status", "draft"), "comment": i.get("comment", "")})
    return out


def check_line(cc, acc, sc):
    if sc["centers"] is not None and cc not in sc["centers"]:
        raise ana.Error("INVALID_PARAMETER", f"centro de custo {cc} fora do escopo da grade")
    if sc["account"] and not acc.startswith(sc["account"]):
        raise ana.Error("INVALID_PARAMETER", f"conta {acc} fora do escopo da grade")
    if not ana.sql_value("SELECT count(*) FROM finance.cost_center WHERE code = $1", cc):
        raise ana.Error("INVALID_PARAMETER", f"centro de custo {cc} inexistente")
    if not ana.sql_value("SELECT count(*) FROM finance.account WHERE code = $1 AND postable", acc):
        raise ana.Error("INVALID_PARAMETER", f"conta {acc} inexistente ou não lançável")
