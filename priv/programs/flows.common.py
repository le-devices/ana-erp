# ana:description Regras comuns das esteiras: situação, parâmetros das etapas e textos
# ana:kind library
"""Spec 030. Shared by the flow screens. render() mirrors the engine (ana_flows:render/2):
"{{field}}" alone keeps the fact's type; inside a text it is interpolated."""

import re

STEP_STATUS = {"pending": "a fazer", "ready": "na fila", "running": "rodando", "waiting": "aguardando",
               "done": "concluída", "failed": "falhou", "skipped": "pulada", "cancelled": "cancelada"}
HOW = {"auto": "automática", "manual": "por uma pessoa", "outside": "já estava concluída", "skipped": "pulada"}
MODE = {"auto": "automática", "manual": "manual", "wait": "aguarda evento"}
OPS = [["<=", "até (≤)"], ["<", "menor que"], [">=", "a partir de (≥)"], [">", "maior que"], ["=", "igual a"], ["!=", "diferente de"]]
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


def condition_text(rules):
    if not rules:
        return "sempre"
    ops = dict(OPS)
    return " e ".join(f"{r.get('field')} {ops.get(r.get('op'), r.get('op'))} {r.get('value')}" for r in rules)


def definition(code):
    d = ana.sql_one("SELECT code, name, description, document, active, run_as FROM flow.definition WHERE code = $1", code)
    if not d:
        raise ana.Error("FLOW_NOT_FOUND", f"esteira {code} não existe")
    return d
