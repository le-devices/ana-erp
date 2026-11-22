# ana:description Uso simulado: o próximo passo de um cenário — personas percorrendo esteiras inteiras com variação e semente
# ana:menu no
"""Spec 067 (D2, RF-067-02). A scenario is a business pipeline from start to end — sale, purchase, field service,
production, project, stock — with variation drawn from the run's seed: items, quantities, partial deliveries,
cancellations, returns, partial receipts, and the human mistakes of each persona. The core asks the next step, runs it
as the persona's robot user (its own execution, its own COMMIT — the pipelines' automation runs as in real use), and
asks again with the result. Same seed, same data, same version: the same steps (RNF-067-02).

The answer is one of:
  {"action": "run", "persona", "program", "params", "save"?, "may_fail"?, "advance"?, "mistake"?}
  {"action": "probe", "probe": {...}, "timeout_s", "title"}   — wait until the pipeline reaches a state (simulation.probe)
  {"action": "done"}
This program only reads (it runs read-only): it decides, it does not act."""

import datetime
import random

PARAMS = {"state": {"type": "dict", "required": True, "label": "estado do cenário"}}

# D1: how often each scenario happens in a working day (the mix of a small company that sells, buys, serves and makes).
MIX = {"venda": 4, "compra": 2, "campo": 1, "producao": 1, "projeto": 1, "estoque": 1}
# Flow steps the pipelines automate when the run turns the flows on (the same as the business-process trails, spec 042).
FLOWS = {"purchase": {1: "auto", 2: "auto"}, "field": {3: "auto"}, "production": {1: "auto", 2: "auto", 4: "auto"}}


def rng(state, *parts):
    return random.Random(":".join(str(p) for p in (state["seed"], state.get("instance", 0), state["scenario"], *parts)))


def today(offset=0):
    return (datetime.date.today() + datetime.timedelta(days=offset)).isoformat()


def run(persona, program, params, save=None, may_fail=False):
    return {"action": "run", "persona": persona, "program": program, "params": params, "save": save, "may_fail": may_fail}


def probe(title, timeout_s=90, **p):
    return {"action": "probe", "probe": p, "timeout_s": timeout_s, "title": title}


def statement(lines):
    """The money arrives (or leaves) in the bank with the document's number: the bill settles by itself."""
    day = datetime.date.today().strftime("%d/%m/%Y")
    csv = "data;histórico;valor\n" + "".join(f"{day};{d};{str(a).replace('.', ',')}\n" for d, a in lines)
    return {"bank_account": "CAIXA", "format": "csv", "content": csv}


# ------------------------------------------------------------------ setup of the run (as who started it)
def names(tag):
    """The run's own records, named by its tag: nothing of the company's is touched."""
    return {"goods": [f"SIM{tag}A", f"SIM{tag}B"], "component": f"SIM{tag}C", "made": f"SIM{tag}M", "service": f"SIM{tag}S",
            "tag": tag}


def setup(state, s, r):
    n = names(state["tag"])
    tag, goods, comp, made, service = n["tag"], n["goods"], n["component"], n["made"], n["service"]
    prof = ana.sql_value("SELECT code FROM projects.rate_profile ORDER BY code LIMIT 1")
    return [
        run("admin", "base.save_party", {"name": f"Cliente Simulado {tag}", "state": "SP"}, "customer"),
        run("admin", "base.save_party", {"name": f"Fornecedor Simulado {tag}", "kind": "supplier", "state": "SP"}, "supplier"),
        run("admin", "base.save_product", {"code": goods[0], "description": f"Mercadoria simulada A {tag}", "price": "50"}),
        run("admin", "base.save_product", {"code": goods[1], "description": f"Mercadoria simulada B {tag}", "price": "35"}),
        run("admin", "base.save_product", {"code": service, "description": f"Serviço simulado {tag}", "price": "80", "kind": "service"}),
        run("admin", "base.save_product", {"code": comp, "description": f"Componente simulado {tag}", "price": "5"}),
        run("admin", "base.save_product", {"code": made, "description": f"Produto fabricado simulado {tag}", "price": "90"}),
        run("admin", "inventory.stock_in", {"product": goods[0], "quantity": 2000, "warehouse": "CENTRAL", "unit_cost": "20"}),
        run("admin", "inventory.stock_in", {"product": goods[1], "quantity": 2000, "warehouse": "CENTRAL", "unit_cost": "15"}),
        run("admin", "inventory.stock_in", {"product": goods[0], "quantity": 200, "warehouse": "LAB", "unit_cost": "20"}),
        run("admin", "inventory.stock_in", {"product": comp, "quantity": 5000, "warehouse": "CENTRAL", "unit_cost": "5"}),
        run("admin", "logistics.save_carrier", {"name": f"Transportadora Simulada {tag}"}, "carrier"),
        run("admin", "production.save_item_plan", {"product": made, "make_or_buy": "make", "lead_time_days": 1, "standard_cost": "12"}),
        run("admin", "production.save_structure", {"product": made, "lines": [{"component": comp, "quantity": 2}]}),
        run("admin", "projects.save_employee", {"name": f"Técnico Simulado {tag}", "profile": prof, "hourly_cost": "40"}, "employee"),
        lambda: run("admin", "field.save_technician", {"employee": s["employee"]["id"], "warehouse": "LAB"}),
        lambda: run("admin", "supply.save_supplier_item", {"product": goods[0], "supplier": s["supplier"]["id"], "price": "20",
                                                            "lead_time_days": 3, "preferred": True}),
        run("admin", "supply.settings", {"limit_kind": "group", "limit_target": "sim_aprovadores"}),
    ]


# ------------------------------------------------------------------ scenarios
def venda(state, s, r):
    u = state["setup"]
    qty = r.randint(1, 5)
    lines = [{"product": r.choice(u["goods"]), "quantity": qty}]
    if r.random() < 0.4:
        lines.append({"product": u["service"], "quantity": 1})
    cancel = r.random() < 0.15
    deliver = r.random() < 0.7
    give_back = r.random() < 0.2
    n = lambda: s["order"]["number"]                                            # noqa: E731
    steps = [run("vendedor", "sales.create_order", {"customer": u["customer"], "items": lines}, "order")]
    if cancel:
        return steps + [run("vendedor", "sales.cancel_order", {"number": n}, "cancel")]
    steps += [lambda: run("almoxarife", "logistics.ship", {"order": n(), "carrier": u["carrier"]}, "shipment")]
    if deliver:
        steps += [lambda: run("almoxarife", "logistics.deliver", {"shipment": s["shipment"]["shipment"], "received_by": "Cliente"})
                  if s.get("shipment", {}).get("shipment") else None]
    steps += [lambda: run("financeiro", "sales.invoice_order", {"number": n()})]
    if give_back:
        steps += [lambda: run("almoxarife", "logistics.register_return", {"customer": u["customer"], "order": n(),
                                                                           "items": [{"product": lines[0]["product"], "quantity": 1}],
                                                                           "reason": "simulação: cliente devolveu"})]
    steps += [lambda: pay_doc(f"ORD-{n()}")]
    return steps


def pay_doc(doc):
    bills = ana.sql("SELECT document, amount FROM finance.bill WHERE status = 'open' AND (document = $1 OR document LIKE $1 || '/%') "
                    "ORDER BY id", doc)
    if not bills:
        return None
    return run("financeiro", "finance.import_statement", statement([(f"PIX {b['document']} CLIENTE", b["amount"]) for b in bills]))


def compra(state, s, r):
    u = state["setup"]
    qty = r.randint(5, 20)
    partial = r.random() < 0.3
    give_back = r.random() < 0.1
    auto = state.get("flows_on")
    req = lambda: s["request"]["number"]                                         # noqa: E731
    steps = [run("comprador", "supply.request_purchase", {"reason": "simulação", "product": u["goods"][0], "quantity": qty}, "request"),
             lambda: run("aprovador", "supply.approve_request", {"request": req()})]
    if auto:
        steps += [lambda: probe("compra aprovada vira ordem de compra sozinha", flow="purchase", key=str(req()), code="order",
                                statuses=["done"])]
    else:
        steps += [lambda: run("comprador", "supply.create_orders", {"requests": [req()]}, "orders")]
    po = lambda: ana.sql_value("SELECT max(o.number) FROM supply.purchase_order o JOIN supply.purchase_order_line l ON l.order_id = o.id "   # noqa: E731
                               "JOIN supply.purchase_request q ON q.id = l.request_id WHERE q.number = $1", req())
    if partial:
        steps += [lambda: run("almoxarife", "supply.receive", {"order": po(), "line": 1, "quantity": max(1, qty // 2)}),
                  lambda: run("almoxarife", "supply.receive", {"order": po(), "line": 1, "quantity": qty - max(1, qty // 2)})]
    else:
        steps += [lambda: run("almoxarife", "supply.receive", {"order": po()})]
    steps += [lambda: pay_supplier(po())]
    if give_back:
        steps += [lambda: run("almoxarife", "supply.return_to_supplier", {"order": po(), "line": 1, "quantity": 1, "reason": "avaria"})]
    return steps


def pay_supplier(po):
    bills = ana.sql("SELECT b.document, b.amount FROM finance.bill b JOIN supply.receipt r ON r.bill_id = b.id "
                    "JOIN supply.purchase_order o ON o.id = r.order_id WHERE o.number = $1 AND b.status = 'open'", po)
    if not bills:
        return None
    return run("financeiro", "finance.import_statement", statement([(f"PAG {b['document']} FORNECEDOR", -float(b["amount"])) for b in bills]))


def campo(state, s, r):
    u = state["setup"]
    auto = state.get("flows_on")
    hours = r.choice([1, 2, 3])
    use_part = r.random() < 0.6
    num = lambda: s["service_order"].get("number") or s["service_order"].get("order")   # noqa: E731
    start = (datetime.datetime.now() + datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M")
    steps = [run("vendedor", "field.open_order", {"customer": u["customer"], "description": "Manutenção simulada", "service": u["service"]},
                 "service_order"),
             lambda: run("gestor", "field.schedule", {"order": num(), "technician": u["employee"]["id"], "start": start}),
             lambda: run("tecnico", "field.start_trip", {"order": num()}),
             lambda: run("tecnico", "field.log_work", {"order": num(), "hours": hours, "km": r.randint(5, 40)})]
    if use_part:
        steps += [lambda: run("tecnico", "field.use_part", {"order": num(), "product": u["goods"][0], "quantity": 1})]
    steps += [lambda: run("tecnico", "field.sign_off", {"order": num(), "signed_by": "Cliente"})]
    if auto:
        steps += [lambda: probe("OS assinada é faturada sozinha", flow="field", key=str(num()), code="receipt", statuses=["waiting", "done"])]
    else:
        steps += [lambda: run("financeiro", "field.invoice_orders", {"orders": [num()]})]
    steps += [lambda: pay_doc(f"OS-{num()}")]
    return steps


def producao(state, s, r):
    u = state["setup"]
    auto = state.get("flows_on")
    qty = r.randint(2, 10)
    wo = lambda: s["work_order"]["order"]                                        # noqa: E731
    steps = [run("producao", "production.create_order", {"product": u["made"], "quantity": qty, "warehouse": "CENTRAL",
                                                         "due_date": today(3)}, "work_order")]
    if auto:
        steps += [lambda: probe("ordem liberada e componentes requisitados sozinhos", flow="production", key=str(wo()), code="make",
                                statuses=["waiting"])]
    else:
        steps += [lambda: run("producao", "production.release_order", {"order": wo()}),
                  lambda: run("almoxarife", "production.issue_components", {"order": wo()})]
    steps += [lambda: run("producao", "production.deliver", {"order": wo(), "good_qty": qty, "complete": True})]
    if auto:
        steps += [lambda: probe("ordem entregue é encerrada sozinha", flow="production", key=str(wo()), code="close", statuses=["done"])]
    else:
        steps += [lambda: run("producao", "production.close_order", {"order": wo()})]
    return steps


def projeto(state, s, r):
    u = state["setup"]
    code = f"S{u['tag']}{state.get('instance', 0)}"[:20]
    hours = r.randint(2, 8)
    # Creating a project is the administrator's (the product's rule); the manager runs it from there.
    steps = [run("admin", "projects.save_project", {"code": code, "name": f"Projeto simulado {code}", "customer": u["customer"],
                                                     "billing": "hourly", "manager": state["personas"]["gestor"]["username"]}),
             run("gestor", "projects.save_activity", {"project": code, "code": "1", "name": "Atividade", "planned_hours": 20}),
             run("gestor", "projects.allocate", {"project": code, "activity": "1", "employee": u["employee"]["id"], "hours": hours,
                                                 "week": today()}),
             run("gestor", "projects.approve_plan", {"project": code, "low_margin_justification": "projeto do uso simulado"}),
             run("gestor", "projects.log_time", {"project": code, "task": "1", "hours": hours, "description": "trabalho simulado",
                                                 "employee": u["employee"]["id"]}),
             run("gestor", "projects.approve_time", {"project": code}),
             run("financeiro", "projects.invoice_project", {"project": code}, "invoice"),
             lambda: pay_bill(s["invoice"].get("bill"))]
    return steps


def pay_bill(bill):
    if not bill:
        return None
    row = ana.sql_one("SELECT document, amount FROM finance.bill WHERE id = $1 AND status = 'open'", bill)
    return run("financeiro", "finance.import_statement", statement([(f"TED {row['document']} CLIENTE", row["amount"])])) if row else None


def estoque(state, s, r):
    u = state["setup"]
    item = r.choice(u["goods"])
    steps = [run("almoxarife", "inventory.write_off", {"product": item, "quantity": 1, "reason": "simulação: quebra"})]
    if r.random() < 0.5:
        steps += [run("almoxarife", "logistics.transfer", {"action": "ship", "from_wh": "CENTRAL", "to_wh": "LAB",
                                                            "items": [{"product": item, "quantity": r.randint(1, 3)}], "notes": "simulação"})]
    return steps


BUILDERS = {"setup": setup, "venda": venda, "compra": compra, "campo": campo, "producao": producao, "projeto": projeto,
            "estoque": estoque}


# ------------------------------------------------------------------ human mistakes (D1)
def mistake(step):
    """What a person gets wrong now and then: a negative quantity, an order without items. The routine must refuse it
    with a message that says what to do — accepting it, or failing with a technical error, is a finding."""
    p = dict(step["params"])
    if "quantity" in p and isinstance(p["quantity"], (int, float)):
        p["quantity"] = -abs(p["quantity"]) or -1
    elif isinstance(p.get("items"), list) and p["items"]:
        p["items"] = []
    else:
        return None
    return {**step, "params": p, "may_fail": True, "advance": False, "mistake": True}


def resolve(value):
    """Values that depend on earlier steps are given as functions; resolved now, with the results so far."""
    if callable(value):
        return value()
    if isinstance(value, dict):
        return {k: resolve(v) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve(v) for v in value]
    return value


def main(state):
    s = dict(state.get("ctx") or {})                            # this scenario's results so far
    # The run's setup for the scenarios: its records by name, and the ids saved by the setup steps.
    done = state.get("setup") or {}
    u = names(state.get("tag", "X"))
    u.update({k: (v["id"] if isinstance(v, dict) and "id" in v and k != "employee" else v) for k, v in done.items()})
    state = {**state, "setup": u}
    builder = BUILDERS.get(state["scenario"])
    if not builder:
        raise ana.Error("UNKNOWN_SCENARIO", f"cenário desconhecido: {state['scenario']}")
    plan = builder(state, s, rng(state))                       # the same choices at every call (same seed)
    i = state.get("step", 0)
    while i < len(plan):
        item = plan[i]
        step = item() if callable(item) else item
        if step is None:                                       # nothing to do here (no bill left, no shipment): next
            i += 1
            continue
        if step["action"] == "run":
            step = {**step, "params": resolve(step["params"])}
            persona = state.get("personas", {}).get(step["persona"], {})
            if (step["persona"] != "admin" and i not in (state.get("mistakes") or [])
                    and rng(state, i, "mistake").random() < float(persona.get("error_rate", 0))):
                wrong = mistake(step)
                if wrong:
                    return {**wrong, "step": i}
        return {**step, "step": i}
    return {"action": "done", "step": i}
