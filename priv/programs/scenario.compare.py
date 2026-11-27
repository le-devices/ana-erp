# ana:description Cenários: base × cenário — a comparação, o que mais pesa e o que fazer
# ana:kind library
"""Spec 069 (T-069-05, RF-069-04, D5). One call makes the base and the scenario (saved scenarios combined, plus loose
shocks), sets them side by side, splits the change among the shocks and the items that cause it, and suggests what
to do — each suggestion opens the routine that does it. Used by the projection (scenario.project) and the screen
(scenario.workbench)."""

import json
from decimal import Decimal

import ana

from ana_lib.scenario import effect, projection
from ana_lib.scenario import shocks as sh

ZERO = Decimal(0)
SINGLES_MAX = 5         # up to this many shocks, each one is projected alone (the cause of each effect, the weights)


def combined(ids, extra):
    """The shocks of the scenarios (one's own or shared with a group of theirs) and the loose ones, checked again with
    this person's scope (what they point to may have changed, or be out of their reach: D8)."""
    ids = [int(i) for i in (ids or [])]
    rows = ana.sql("SELECT id, name, shocks FROM scenario.scenario WHERE id = ANY($1) "
                   "AND (owner = $2 OR shared_group IN (SELECT g FROM bpm.user_groups($2) AS g)) ORDER BY id",
                   ids, ana.context.user) if ids else []
    missing = sorted(set(ids) - {r["id"] for r in rows})
    if missing:
        raise ana.Error("SCENARIO_NOT_FOUND", f"cenário não encontrado ou não compartilhado: {', '.join(map(str, missing))}")
    all_shocks = []
    for r in rows:
        all_shocks += json.loads(r["shocks"]) if isinstance(r["shocks"], str) else r["shocks"]
    all_shocks += list(extra or [])
    return [r["name"] for r in rows], sh.validate(all_shocks)


def margin_total(o):
    return sum((Decimal(r["margin"]) for r in o["result"]["customers"]), ZERO)


def compare(base, scen, cash):
    """Scenario against the base: margin by line, deliveries that get later, the lowest cash position."""
    def margins(o, dim):
        return {r["key"]: r["margin"] for r in o["result"][dim]}

    out = {"margin_by_group": [], "deliveries_late": []}
    bg, sg = margins(base, "groups"), margins(scen, "groups")
    for k in sorted(set(bg) | set(sg), key=str):
        out["margin_by_group"].append({"group": k, "base": bg.get(k, 0), "scenario": sg.get(k, 0),
                                       "change": sg.get(k, 0) - bg.get(k, 0)})
    risk = {r["doc"]: r for r in base["deliveries_at_risk"]}
    out["deliveries_late"] = [r for r in scen["deliveries_at_risk"] if r["doc"] not in risk or risk[r["doc"]]["date"] != r["date"]]
    out["margin"] = {"base": margin_total(base), "scenario": margin_total(scen)}
    out["margin"]["change"] = out["margin"]["scenario"] - out["margin"]["base"]
    if cash:
        out["lowest"] = {"base": base["lowest"], "scenario": scen["lowest"],
                         "change": scen["lowest"]["balance"] - base["lowest"]["balance"]}
        # Working capital the scenario asks for: how far below zero the cash goes, beyond what the base already needed.
        need = lambda o: max(ZERO, -Decimal(o["lowest"]["balance"]))  # noqa: E731
        out["working_capital"] = {"base": need(base), "scenario": need(scen), "change": need(scen) - need(base)}
    return out


def weights(base, scen, singles_out, checked, cash):
    """What weighs most: each shock's share of the change (projected alone), and the items that carry the change in
    margin ("80% do efeito vem do item X")."""
    by_shock = []
    if singles_out:
        rows = []
        for i, o in sorted(singles_out.items()):
            rows.append({"shock": checked[i]["label"], "margin": margin_total(o) - margin_total(base),
                         "cash": (Decimal(o["lowest"]["balance"]) - Decimal(base["lowest"]["balance"])) if cash else None})
        for key in ("margin", "cash"):
            total = sum((abs(r[key]) for r in rows if r[key] is not None), ZERO)
            for r in rows:
                r[f"{key}_share"] = (int((abs(r[key]) / total * 100).quantize(Decimal(1))) if total and r[key] is not None
                                     else None)
        by_shock = sorted(rows, key=lambda r: -(abs(r["margin"]) + abs(r["cash"] or 0)))
    elif len(checked) == 1:
        by_shock = [{"shock": checked[0]["label"], "margin": margin_total(scen) - margin_total(base), "margin_share": 100,
                     "cash": (Decimal(scen["lowest"]["balance"]) - Decimal(base["lowest"]["balance"])) if cash else None,
                     "cash_share": 100 if cash else None}]
    bi = {r["key"]: Decimal(r["margin"]) for r in base["result"]["items"]}
    si = {r["key"]: Decimal(r["margin"]) for r in scen["result"]["items"]}
    items = sorted(({"item": k, "change": si.get(k, ZERO) - bi.get(k, ZERO)} for k in set(bi) | set(si)),
                   key=lambda r: (-abs(r["change"]), str(r["item"])))
    items = [r for r in items if r["change"]]
    total = sum((abs(r["change"]) for r in items), ZERO)
    for r in items:
        r["share"] = int((abs(r["change"]) / total * 100).quantize(Decimal(1))) if total else 0
    return {"by_shock": by_shock, "by_item": items[:10]}


def suggestions(checked, cmp, codes, cash):
    """What to do, from the result: each one opens the routine that does it (spec 013 for purchases, 031 for credit)."""
    out = []
    kinds = {s["kind"] for s in checked}
    late_items = []
    for r in cmp["deliveries_late"]:
        code = codes.get(r.get("item"))
        if code and code not in late_items:
            late_items.append(code)
    if kinds & {"supplier_delay", "supplier_stops"} or cmp["deliveries_late"]:
        out.append({"label": "Acompanhar as compras a receber", "program": "supply.workbench", "params": {"view": "receive"},
                    "open": True})
        for code in late_items[:3]:
            out.append({"label": f"Buscar outro fornecedor do item {code}", "program": "supply.save_supplier_item",
                        "params": {"product": code}, "open": True})
    if kinds & {"currency", "purchase_price"} and cmp["margin"]["change"] < 0:
        out.append({"label": "Rever os fornecedores e preços de compra", "program": "supply.workbench",
                    "params": {"view": "buy"}, "open": True})
    if kinds & {"customer_delay", "customer_stops", "payment_terms"} and cash:
        out.append({"label": "Rever o crédito e os prazos dos clientes", "program": "finance.credit_report",
                    "params": {"only_issues": False}, "open": True})
    if "capacity" in kinds:
        out.append({"label": "Replanejar a produção", "program": "production.workbench", "params": {}, "open": True})
    if cash and cmp.get("working_capital", {}).get("change", ZERO) > 0:
        out.append({"label": "Ver os títulos a receber em atraso", "program": "finance.credit_report",
                    "params": {"only_issues": True}, "open": True})
    seen, unique = set(), []
    for a in out:
        k = (a["program"], json.dumps(a["params"], sort_keys=True))
        if k not in seen and ana.can_run(a["program"]):
            seen.add(k)
            unique.append(a)
    return unique


def run(weeks, ids=None, loose=None, cash=True):
    """{"base": weekly, "scenario"?: weekly + names + shocks, "compare"?: …} and the base graph (for its notes)."""
    names, checked = combined(ids, loose) if (ids or loose) else ([], None)
    g = projection.build(weeks, cash=cash)
    out = {"base": projection.weekly(g, cash=cash), "graph": g}
    if checked is None:
        return out
    gs = sh.project(checked, weeks, cash=cash)
    scen = {"names": names, "shocks": checked, **projection.weekly(gs, cash=cash)}
    singles = ({i: sh.project([s], weeks, cash=cash) for i, s in enumerate(checked)}
               if 1 < len(checked) <= SINGLES_MAX else None)
    cmp = compare(out["base"], scen, cash)
    cmp.update(effect.explain(g, gs, checked, singles, cash=cash))
    cmp["weights"] = weights(out["base"], scen, {i: projection.weekly(x, cash=cash) for i, x in (singles or {}).items()},
                             checked, cash)
    items = {r["item"] for r in cmp["weights"]["by_item"]} | {e.get("item") for e in gs.events if e["kind"] == "delivery"}
    codes = {r["id"]: r["code"] for r in ana.sql("SELECT id, code FROM base.product WHERE id = ANY($1)",
                                                 sorted(i for i in items if i is not None))}
    for r in cmp["weights"]["by_item"]:
        r["code"] = codes.get(r["item"], r["item"])
    late = {e["doc"]: e.get("item") for e in gs.events if e["kind"] == "delivery"}
    for r in cmp["deliveries_late"]:
        r["item"] = late.get(r["doc"])
    cmp["suggestions"] = suggestions(checked, cmp, codes, cash)
    out.update(scenario=scen, compare=cmp, scenario_graph=gs)
    return out
