# ana:description BPM: regras comuns — elementos, permissões, validação ao desenhar e compilação para publicar
# ana:kind library
"""Spec 039. The model is canonical JSON with BPMN meaning:
  nodes  [{id, type, name, lane, x, y, props}]
  edges  [{id, from, to, name, condition: [{field, op, value}], default: bool, on: "error" | "timeout"}]
  lanes  [{id, name, role, group}]    variables [{name, label, type}]    document: entity followed
Conditions are restricted rules (never code), evaluated by the engine without eval."""

import re

import ana

TYPES = {
    "start": {"label": "Início", "group": "Eventos"},
    "end": {"label": "Fim", "group": "Eventos"},
    "timer": {"label": "Espera por tempo", "group": "Eventos"},
    "event_fact": {"label": "Espera por fato do ERP", "group": "Eventos"},
    "task_human": {"label": "Tarefa de pessoa", "group": "Tarefas"},
    "task_approval": {"label": "Aprovação", "group": "Tarefas"},
    "task_auto": {"label": "Tarefa automática (programa)", "group": "Tarefas"},
    "task_send": {"label": "Envio (mensagem)", "group": "Tarefas"},
    "task_rule": {"label": "Regra de decisão", "group": "Tarefas"},
    "subprocess": {"label": "Subprocesso", "group": "Tarefas"},
    "gw_xor": {"label": "Decisão (um caminho)", "group": "Caminhos"},
    "gw_and": {"label": "Paralelo (todos)", "group": "Caminhos"},
    "gw_or": {"label": "Inclusivo (os que valerem)", "group": "Caminhos"},
    "annotation": {"label": "Anotação", "group": "Outros"},
}
TASKS = {"task_human", "task_approval", "task_auto", "task_send", "task_rule", "subprocess", "timer", "event_fact"}
OPS = {"=", "!=", "<", "<=", ">", ">=", "in"}
ID = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,40}$")
CODE = re.compile(r"^[a-z][a-z0-9_.-]{1,60}$")
ROLE_RANK = {"user": 0, "developer": 1, "admin": 2}


# ---------------------------------------------------------------- permissions (RNF-039-05)
def groups():
    return {r["g"] for r in ana.sql("SELECT g FROM bpm.user_groups($1) AS g", ana.context.user)}


def can_design():
    return ana.context.role in ("developer", "admin") or "processos" in groups()


def require_design():
    if not can_design():
        raise ana.Error("FORBIDDEN", "desenhar processos exige o papel de desenvolvedor ou o grupo \"processos\"")


def can_publish(process):
    return ana.context.role == "admin" or (process.get("owner") and process["owner"] == ana.context.user)


def process(code, lock=False):
    p = ana.sql_one("SELECT * FROM bpm.process WHERE code = $1" + (" FOR UPDATE" if lock else ""), code)
    if not p:
        raise ana.Error("PROCESS_NOT_FOUND", f"processo {code} não encontrado")
    return p


def version(code, which=None):
    """which: a number, 'draft', 'published' or None (draft, else published, else the last)."""
    if isinstance(which, int) or (isinstance(which, str) and which.isdigit()):
        v = ana.sql_one("SELECT * FROM bpm.version WHERE process_code = $1 AND version = $2", code, int(which))
    elif which in ("draft", "published"):
        v = ana.sql_one("SELECT * FROM bpm.version WHERE process_code = $1 AND status = $2", code, which)
    else:
        v = ana.sql_one("SELECT * FROM bpm.version WHERE process_code = $1 ORDER BY (status = 'draft') DESC, "
                        "(status = 'published') DESC, version DESC LIMIT 1", code)
    return v


def empty_model():
    return {"lanes": [{"id": "l1", "name": "Responsável", "role": "user"}], "variables": [], "document": "none",
            "run_as": "system",
            "nodes": [{"id": "start", "type": "start", "name": "Início", "x": 80, "y": 90, "lane": "l1", "props": {"trigger": "manual"}},
                      {"id": "end", "type": "end", "name": "Fim", "x": 420, "y": 90, "lane": "l1", "props": {}}],
            "edges": [{"id": "e1", "from": "start", "to": "end"}]}


# ---------------------------------------------------------------- validation (RF-039-03)
def validate(model, process_code=None):
    """[{level: error|warning, node?, edge?, message}] — errors block publication, never saving a draft."""
    issues = []

    def add(level, msg, node=None, edge=None):
        issues.append({k: v for k, v in (("level", level), ("message", msg), ("node", node), ("edge", edge)) if v is not None})

    if not isinstance(model, dict):
        return [{"level": "error", "message": "modelo inválido"}]
    nodes = model.get("nodes") or []
    edges = model.get("edges") or []
    lanes = {l.get("id") for l in (model.get("lanes") or []) if isinstance(l, dict)}
    by_id = {}
    for n in nodes:
        nid = n.get("id")
        if not isinstance(nid, str) or not ID.match(nid):
            add("error", f"identificador de elemento inválido: {nid}")
            continue
        if nid in by_id:
            add("error", "identificador repetido", nid)
        by_id[nid] = n
        if n.get("type") not in TYPES:
            add("error", f"tipo desconhecido: {n.get('type')}", nid)
        if n.get("lane") and n["lane"] not in lanes:
            add("error", "raia inexistente", nid)
    work = {k: v for k, v in by_id.items() if v.get("type") != "annotation"}
    out, inc = {k: [] for k in by_id}, {k: [] for k in by_id}
    seen = set()
    for e in edges:
        f, t, eid = e.get("from"), e.get("to"), e.get("id")
        if f not in by_id or t not in by_id:
            add("error", "ligação com ponta solta", edge=eid)
            continue
        if (f, t, e.get("on")) in seen:
            add("warning", "ligação repetida", edge=eid)
        seen.add((f, t, e.get("on")))
        out[f].append(e)
        inc[t].append(e)
        if e.get("on") not in (None, "error", "timeout"):
            add("error", "tipo de ligação desconhecido", edge=eid)
        if e.get("on") and by_id[f].get("type") not in TASKS:
            add("error", "caminho de erro ou de atraso só sai de tarefas", edge=eid)
        for r in e.get("condition") or []:
            if not isinstance(r, dict) or not r.get("field") or r.get("op") not in OPS:
                add("error", "condição incompleta (campo, operador e valor)", edge=eid)
    starts = [k for k, v in work.items() if v["type"] == "start"]
    ends = [k for k, v in work.items() if v["type"] == "end"]
    if not starts:
        add("error", "falta o evento de início")
    if len(starts) > 1:
        add("error", "use um único início (separe em subprocessos se precisar)", starts[1])
    if not ends:
        add("error", "falta o evento de fim")
    for k, n in work.items():
        t = n["type"]
        p = n.get("props") or {}
        if t == "start" and inc[k]:
            add("error", "o início não recebe ligações", k)
        if t == "end" and out[k]:
            add("error", "o fim não tem saída", k)
        if t not in ("end",) and not [e for e in out[k] if not e.get("on")]:
            add("error", "elemento sem saída", k)
        if t != "start" and not inc[k]:
            add("error", "elemento sem entrada (nunca será alcançado)", k)
        if t in ("task_human", "task_approval"):
            lane = next((l for l in model.get("lanes") or [] if l.get("id") == n.get("lane")), {})
            if not (p.get("assignee") or p.get("role") or p.get("group") or lane.get("role") or lane.get("group")):
                add("error", "tarefa sem responsável (pessoa, papel ou grupo, ou a raia)", k)
            if p.get("escalate", {}).get("mode") == "path" and not [e for e in out[k] if e.get("on") == "timeout"]:
                add("error", "escalonamento por caminho exige uma ligação de atraso", k)
        if t in ("task_auto", "task_send") and not p.get("program"):
            add("error", "tarefa automática sem programa", k)
        if t == "subprocess" and not p.get("process"):
            add("error", "subprocesso sem processo", k)
        if t == "subprocess" and p.get("process") == process_code:
            add("error", "um processo não chama a si mesmo", k)
        if t == "timer" and not _num(p.get("hours")):
            add("error", "espera sem tempo (horas)", k)
        if t == "event_fact" and not p.get("fact"):
            add("error", "espera sem o fato do ERP", k)
        if t == "gw_xor" and len(out[k]) > 1:
            if not any(e.get("default") for e in out[k]):
                add("error", "decisão sem saída padrão", k)
            if [e for e in out[k] if not e.get("default") and not e.get("condition")]:
                add("warning", "caminho sem condição numa decisão: será sempre o primeiro", k)
        if t == "task_rule" and not isinstance(p.get("assign", []), list):
            add("error", "regra mal formada", k)
    # Reachability: from the start to every element, and every element to an end (no loop without exit).
    if starts:
        reach = _reach_from(starts[0], out)
        for k in work:
            if k not in reach and k != starts[0]:
                add("error", "elemento inalcançável a partir do início", k)
    if ends:
        back = set()
        stack = list(ends)
        while stack:
            k = stack.pop()
            if k in back:
                continue
            back.add(k)
            stack.extend(e["from"] for e in inc.get(k, []))
        for k in work:
            if k not in back:
                add("error", "daqui não se chega a um fim (laço sem saída?)", k)
    # Programs, processes, facts and documents that exist.
    programs = {p.get("props", {}).get("program") for p in work.values() if p.get("props", {}).get("program")}
    if programs:
        known = {r["n"] for r in ana.sql("SELECT n FROM bpm.program_names() AS n WHERE n = ANY($1)", sorted(programs))}
        for k, n in work.items():
            pr = (n.get("props") or {}).get("program")
            if pr and pr not in known:
                add("error", f"programa {pr} inexistente ou inativo", k)
    facts = {(n.get("props") or {}).get(f) for n in work.values() for f in ("fact", "done_fact") if (n.get("props") or {}).get(f)}
    if facts:
        known = {r["code"] for r in ana.sql("SELECT code FROM bpm.fact WHERE code = ANY($1)", sorted(facts))}
        for k, n in work.items():
            for f in ("fact", "done_fact"):
                v = (n.get("props") or {}).get(f)
                if v and v not in known:
                    add("error", f"fato do ERP desconhecido: {v}", k)
    run_as = model.get("run_as") or "system"
    if run_as != "system" and not ana.sql_value("SELECT bpm.user_exists($1)", run_as):      # system: the built-in robot
        add("error", f"usuário de execução das tarefas automáticas não existe ou está inativo: {run_as}")
    doc = model.get("document") or "none"
    if not ana.sql_value("SELECT count(*) FROM bpm.document WHERE entity = $1", doc):
        add("error", f"documento desconhecido: {doc}")
    for k, n in work.items():
        p = n.get("props") or {}
        if n["type"] == "start" and p.get("trigger") == "document" and p.get("entity") and p.get("entity") != doc:
            add("error", "o início segue um documento diferente do documento do processo", k)
    return issues


def _num(v):
    try:
        return float(str(v).replace(",", ".")) > 0
    except (TypeError, ValueError):
        return False


def _reach_from(start, out):
    seen, stack = set(), [start]
    while stack:
        k = stack.pop()
        for e in out.get(k, []):
            if e["to"] not in seen:
                seen.add(e["to"])
                stack.append(e["to"])
    return seen


def compile_model(model):
    """What the engine needs, computed once at publication: start, start trigger, reachability."""
    nodes = {n["id"]: n for n in model["nodes"]}
    out = {k: [] for k in nodes}
    for e in model["edges"]:
        out.setdefault(e["from"], []).append(e)
    start = next(k for k, n in nodes.items() if n["type"] == "start")
    p = nodes[start].get("props") or {}
    return {"start": start,
            "starts_on": (model.get("document") if p.get("trigger") == "document" and model.get("document") not in (None, "none")
                          else None),
            "reach": {k: sorted(_reach_from(k, out)) for k in nodes},
            "run_as": model.get("run_as") or "system"}


def errors(issues):
    return [i for i in issues if i["level"] == "error"]
