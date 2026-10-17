# ana:description Processos: cria ou altera a ficha de um processo do mapa (nome, nível, dono, objetivo, indicadores) — opcionalmente a partir de um modelo pronto
# ana:exposed yes
"""Spec 039 (RF-039-01, RF-039-07). A new process starts with a draft: empty, or a product template."""

from ana_lib.bpm import common
from ana_lib.bpm import templates

PARAMS = {
    "code": {"type": "str", "required": True, "label": "código (ex.: vendas.pedido)"},
    "name": {"type": "str", "required": True, "label": "nome"},
    "parent": {"type": "str", "label": "processo acima no mapa"},
    "level": {"type": "str", "default": "process", "label": "nível",
              "choices": [["chain", "Cadeia de valor"], ["process", "Processo"], ["subprocess", "Subprocesso"]]},
    "owner": {"type": "str", "label": "dono (usuário)"},
    "objective": {"type": "str", "label": "objetivo"},
    "trigger_text": {"type": "str", "label": "o que dispara"},
    "outcome": {"type": "str", "label": "resultado"},
    "kpi": {"type": "dict", "label": "metas (cycle_hours, cost, on_time_pct)"},
    "tags": {"type": "list", "label": "etiquetas"},
    "template": {"type": "str", "label": "modelo pronto (código)"},
    "active": {"type": "bool", "label": "ativo"},
}


def main(code, name, parent=None, level="process", owner=None, objective=None, trigger_text=None, outcome=None, kpi=None,
         tags=None, template=None, active=None):
    common.require_design()
    code = code.strip().lower()
    if not common.CODE.match(code):
        raise ana.Error("INVALID_PARAMETER", "código: letras minúsculas, números, ponto, hífen ou _ (ex.: vendas.pedido)")
    if parent and parent == code:
        raise ana.Error("INVALID_PARAMETER", "um processo não fica acima de si mesmo")
    if parent:
        common.process(parent)
    if owner and not ana.sql_value("SELECT bpm.user_exists($1)", owner):
        raise ana.Error("INVALID_PARAMETER", f"usuário {owner} não encontrado")
    exists = ana.sql_one("SELECT flow_code FROM bpm.process WHERE code = $1", code)
    if exists and exists["flow_code"] and active is False:
        raise ana.Error("INVALID_PARAMETER", "a esteira se liga e desliga em Esteiras")
    ana.sql_exec(
        "INSERT INTO bpm.process (code, name, parent_code, level, owner, objective, trigger_text, outcome, kpi, tags, created_by) "
        "VALUES ($1, $2, $3, $4, $5, COALESCE($6::text, ''), COALESCE($7::text, ''), COALESCE($8::text, ''), COALESCE($9::jsonb, '{}'::jsonb), COALESCE($10::text[], '{}'::text[]), $11) "
        "ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, parent_code = EXCLUDED.parent_code, level = EXCLUDED.level, "
        "  owner = EXCLUDED.owner, objective = COALESCE($6, bpm.process.objective), "
        "  trigger_text = COALESCE($7, bpm.process.trigger_text), outcome = COALESCE($8, bpm.process.outcome), "
        "  kpi = COALESCE($9::jsonb, bpm.process.kpi), tags = COALESCE($10::text[], bpm.process.tags), "
        "  active = COALESCE($12::boolean, bpm.process.active), updated_by = $11, updated_at = now()",
        code, name.strip(), parent or None, level, owner or None, objective, trigger_text, outcome, kpi,
        [str(t) for t in tags] if tags is not None else None, ana.context.user, active)
    created = False
    if not exists:
        model = common.empty_model()
        if template:
            t = next((x for x in templates.TEMPLATES if x["code"] == template), None)
            if not t:
                raise ana.Error("INVALID_PARAMETER", f"modelo pronto {template} não existe")
            model = t["model"]
            if not objective:
                ana.sql_exec("UPDATE bpm.process SET objective = $2 WHERE code = $1", code, t["description"])
        ana.sql_exec("INSERT INTO bpm.version (process_code, version, model, created_by, comment) VALUES ($1, 1, $2, $3, $4)",
                     code, model, ana.context.user, f"modelo pronto: {template}" if template else "")
        created = True
    return {"code": code, "created": created}
