# ana:description Regras comuns das esteiras: situação, parâmetros das etapas e textos
# ana:kind library
"""Spec 030. Shared by the flow screens. render() mirrors the engine (ana_flows:render/2):
"{{field}}" alone keeps the fact's type; inside a text it is interpolated."""

import datetime
import decimal
import re

from ana_lib.util import conditions

STEP_STATUS = {"pending": "a fazer", "ready": "na fila", "running": "rodando", "waiting": "aguardando",
               "done": "concluída", "failed": "falhou", "skipped": "pulada", "cancelled": "cancelada"}
HOW = {"auto": "automática", "manual": "por uma pessoa", "outside": "já estava concluída", "skipped": "pulada"}
MODE = {"auto": "automática", "manual": "manual", "wait": "aguarda evento"}
OPS = [["<=", "até (≤)"], ["<", "menor que"], [">=", "a partir de (≥)"], [">", "maior que"], ["=", "igual a"], ["!=", "diferente de"]]
INSTANCE_STATUS = {"running": "andando", "waiting": "aguardando", "failed": "com falha", "done": "concluída", "cancelled": "cancelada"}
# Names of the facts read by the product's flows (facts_sql), as people call them.
FACT_LABELS = {"number": "Número", "total": "Total", "customer_id": "Cliente (código)", "customer": "Cliente",
               "payment_term": "Condição de pagamento", "payment_method": "Forma de pagamento", "warehouse": "Depósito",
               "status": "Situação", "origin": "Origem", "requester": "Solicitante", "purchase_order": "Ordem de compra",
               "priority": "Prioridade", "project": "Tem projeto", "product": "Produto", "quantity": "Quantidade",
               "due_date": "Data de entrega"}
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}")
_NUM = re.compile(r"^-?\d+(\.\d+)?$")
_ONE = re.compile(r"^\{\{([a-z_][a-z0-9_]*)\}\}$")
_ANY = re.compile(r"\{\{([a-z_][a-z0-9_]*)\}\}")


def render(template, facts):
    if isinstance(template, str):
        m = _ONE.match(template)
        if m:
            return facts.get(m.group(1))
        return _ANY.sub(lambda x: "" if facts.get(x.group(1)) is None else str(facts.get(x.group(1))), template)
    if isinstance(template, list):
        return [render(t, facts) for t in template]
    if isinstance(template, dict):
        return {k: render(v, facts) for k, v in template.items()}
    return template


def condition_text(rules, flow=None):
    """The step's rule in Portuguese (criteria and exceptions, RF-020-14), with the facts' names."""
    return conditions.text(rules, fact_labels(flow) if flow else None)


def definition(code):
    d = ana.sql_one("SELECT code, name, description, document, active, run_as FROM flow.definition WHERE code = $1", code)
    if not d:
        raise ana.Error("FLOW_NOT_FOUND", f"esteira {code} não existe")
    return d


def fact_labels(flow):
    return {f["name"]: f["label"] for f in fact_fields(flow)}


def fact_fields(flow):
    """[{name, label, type}] of the facts a flow reads about its documents (condition builder, RF-020-14):
    the columns of the latest facts, or of an open document when the flow has none yet."""
    sample = ana.sql_value("SELECT facts FROM flow.instance WHERE flow_code = $1 AND facts IS NOT NULL ORDER BY id DESC LIMIT 1", flow)
    if not sample:
        d = ana.sql_one("SELECT facts_sql, open_sql FROM flow.definition WHERE code = $1", flow)
        key = ana.sql_value(f"SELECT * FROM ({d['open_sql']}) k LIMIT 1") if d else None
        sample = ana.sql_one(d["facts_sql"], str(key)) if key is not None else None
    out = []
    for k, v in (sample or {}).items():
        if k == "key":
            continue
        kind = ("bool" if isinstance(v, bool) else "number" if isinstance(v, (int, float, decimal.Decimal)) or _NUM.match(str(v))
                else "date" if isinstance(v, (datetime.date, str)) and _DATE.match(str(v)) else "text")
        out.append({"name": k, "label": FACT_LABELS.get(k, k.replace("_", " ").capitalize()), "type": kind})
    return out
