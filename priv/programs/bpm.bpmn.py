# ana:description Processos: exporta um processo em BPMN 2.0 (XML) ou importa um XML BPMN como rascunho, avisando o que não é suportado
# ana:exposed yes
# ana:category Processos/Modelagem
"""Spec 039 (RF-039-07, CA-039-06). Elements with BPMN meaning go both ways, with the diagram (BPMNDI);
what ANA needs beyond BPMN (programs, facts, rules) travels in extension attributes (ana:props,
ana:condition). Unsupported elements are listed, never dropped silently. DOCTYPE is refused (no
entities: protection against XML attacks)."""

import json
import re
import xml.etree.ElementTree as ET

from ana_lib.bpm import common
from ana_lib.util import conditions

PARAMS = {
    "action": {"type": "str", "required": True, "label": "ação", "choices": [["export", "Exportar"], ["import", "Importar"]]},
    "process": {"type": "str", "label": "processo"},
    "version": {"type": "str", "label": "versão (exportar)"},
    "xml": {"type": "str", "label": "XML BPMN (importar)"},
}
NS = {"bpmn": "http://www.omg.org/spec/BPMN/20100524/MODEL", "bpmndi": "http://www.omg.org/spec/BPMN/20100524/DI",
      "dc": "http://www.omg.org/spec/DD/20100524/DC", "di": "http://www.omg.org/spec/DD/20100524/DI",
      "ana": "https://ana-erp.example/bpmn"}
TO_BPMN = {"start": "startEvent", "end": "endEvent", "task_human": "userTask", "task_approval": "userTask",
           "task_auto": "serviceTask", "task_send": "sendTask", "task_rule": "businessRuleTask", "subprocess": "callActivity",
           "gw_xor": "exclusiveGateway", "gw_and": "parallelGateway", "gw_or": "inclusiveGateway", "timer": "intermediateCatchEvent",
           "event_fact": "intermediateCatchEvent", "annotation": "textAnnotation"}
SIZE = {"start": (36, 36), "end": (36, 36), "timer": (36, 36), "event_fact": (36, 36), "gw_xor": (50, 50), "gw_and": (50, 50),
        "gw_or": (50, 50)}


def q(tag, ns="bpmn"):
    return f"{{{NS[ns]}}}{tag}"


def main(action, process=None, version=None, xml=None):
    if action == "export":
        return export(process, version)
    common.require_design()
    return do_import(process, xml or "")


# ---------------------------------------------------------------- export
def export(code, which):
    p = common.process(code)
    v = common.version(code, which or None)
    m = v["model"]
    for k, uri in NS.items():
        ET.register_namespace(k if k != "bpmn" else "bpmn", uri)
    defs = ET.Element(q("definitions"), {"id": "defs", "targetNamespace": NS["ana"], "exporter": "ANA ERP", "exporterVersion": "039"})
    proc = ET.SubElement(defs, q("process"), {"id": "p_" + re.sub(r"[^A-Za-z0-9_]", "_", code), "name": p["name"], "isExecutable": "true",
                                              q("props", "ana"): json.dumps({k: m.get(k) for k in ("document", "run_as", "variables")},
                                                                            ensure_ascii=False)})
    if m.get("lanes"):
        ls = ET.SubElement(proc, q("laneSet"), {"id": "lanes"})
        for lane in m["lanes"]:
            el = ET.SubElement(ls, q("lane"), {"id": lane["id"], "name": lane.get("name", ""),
                                               q("props", "ana"): json.dumps({k: lane[k] for k in ("role", "group") if lane.get(k)})})
            for n in m["nodes"]:
                if n.get("lane") == lane["id"]:
                    ET.SubElement(el, q("flowNodeRef")).text = n["id"]
    for n in m["nodes"]:
        attrs = {"id": n["id"], "name": n.get("name", "")}
        props = dict(n.get("props") or {})
        props["ana_type"] = n["type"]
        attrs[q("props", "ana")] = json.dumps(props, ensure_ascii=False)
        e = ET.SubElement(proc, q(TO_BPMN[n["type"]]), attrs)
        if n["type"] == "timer":
            t = ET.SubElement(e, q("timerEventDefinition"))
            ET.SubElement(t, q("timeDuration")).text = f"PT{props.get('hours', 1)}H"
        if n["type"] == "event_fact":
            c = ET.SubElement(e, q("conditionalEventDefinition"))
            ET.SubElement(c, q("condition")).text = props.get("fact", "")
        if n["type"] == "annotation":
            ET.SubElement(e, q("text")).text = n.get("name", "")
    for ed in m["edges"]:
        attrs = {"id": ed["id"], "sourceRef": ed["from"], "targetRef": ed["to"], "name": ed.get("name", "")}
        extra = {k: ed[k] for k in ("condition", "default", "on") if ed.get(k) not in (None, [], False)}
        if extra:
            attrs[q("condition", "ana")] = json.dumps(extra, ensure_ascii=False)
        f = ET.SubElement(proc, q("sequenceFlow"), attrs)
        if ed.get("condition"):
            ET.SubElement(f, q("conditionExpression")).text = conditions.text(ed["condition"])
    for ed in m["edges"]:
        if ed.get("default"):
            src = proc.find(f"*[@id='{ed['from']}']")
            if src is not None:
                src.set("default", ed["id"])
    dia = ET.SubElement(defs, q("BPMNDiagram", "bpmndi"), {"id": "dia"})
    plane = ET.SubElement(dia, q("BPMNPlane", "bpmndi"), {"id": "plane", "bpmnElement": proc.get("id")})
    pos = {}
    for n in m["nodes"]:
        w, h = SIZE.get(n["type"], (120, 60))
        x, y = float(n.get("x", 0)), float(n.get("y", 0))
        pos[n["id"]] = (x, y, w, h)
        s = ET.SubElement(plane, q("BPMNShape", "bpmndi"), {"id": "s_" + n["id"], "bpmnElement": n["id"]})
        ET.SubElement(s, q("Bounds", "dc"), {"x": str(x), "y": str(y), "width": str(w), "height": str(h)})
    for ed in m["edges"]:
        if ed["from"] in pos and ed["to"] in pos:
            a, b = pos[ed["from"]], pos[ed["to"]]
            e = ET.SubElement(plane, q("BPMNEdge", "bpmndi"), {"id": "d_" + ed["id"], "bpmnElement": ed["id"]})
            ET.SubElement(e, q("waypoint", "di"), {"x": str(a[0] + a[2]), "y": str(a[1] + a[3] / 2)})
            ET.SubElement(e, q("waypoint", "di"), {"x": str(b[0]), "y": str(b[1] + b[3] / 2)})
    xml = '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(defs, encoding="unicode")
    return {"filename": f"{code}-v{v['version']}.bpmn", "xml": xml}


# ---------------------------------------------------------------- import
FROM_BPMN = {"startEvent": "start", "endEvent": "end", "userTask": "task_human", "manualTask": "task_human",
             "task": "task_human", "serviceTask": "task_auto", "scriptTask": "task_auto", "sendTask": "task_send",
             "businessRuleTask": "task_rule", "callActivity": "subprocess", "exclusiveGateway": "gw_xor",
             "parallelGateway": "gw_and", "inclusiveGateway": "gw_or", "textAnnotation": "annotation"}
IGNORED = {"laneSet", "sequenceFlow", "extensionElements", "documentation", "association", "dataObject", "dataObjectReference",
           "dataStoreReference", "property", "ioSpecification"}


def do_import(code, text):
    if len(text) > 5_000_000:
        raise ana.Error("TOO_LARGE", "arquivo grande demais")
    if re.search(r"<!DOCTYPE|<!ENTITY", text, re.I):
        raise ana.Error("INVALID_XML", "XML com DOCTYPE/ENTITY não é aceito (segurança)")
    try:
        root = ET.fromstring(text)
    except ET.ParseError as e:
        raise ana.Error("INVALID_XML", f"XML inválido: {e}") from None
    proc = root.find("bpmn:process", NS)
    if proc is None:
        raise ana.Error("INVALID_XML", "nenhum <process> BPMN no arquivo")
    warnings, nodes, edges, lanes = [], [], [], []
    bounds = {}
    for s in root.iter(q("BPMNShape", "bpmndi")):
        b = s.find("dc:Bounds", NS)
        if b is not None:
            bounds[s.get("bpmnElement")] = (float(b.get("x", 0)), float(b.get("y", 0)))
    lane_of = {}
    for i, lane in enumerate(proc.iter(q("lane"))):
        lid = safe_id(lane.get("id") or f"l{i + 1}")
        entry = {"id": lid, "name": lane.get("name") or f"Raia {i + 1}"}
        try:
            entry.update({k: v for k, v in json.loads(lane.get(q("props", "ana")) or "{}").items() if k in ("role", "group")})
        except ValueError:
            pass
        lanes.append(entry)
        for ref in lane.findall("bpmn:flowNodeRef", NS):
            lane_of[ref.text] = lid
    col = 0
    for el in list(proc):
        tag = el.tag.split("}")[-1]
        if tag in IGNORED:
            continue
        nid = el.get("id")
        props = {}
        raw = el.get(q("props", "ana"))
        if raw:
            try:
                props = json.loads(raw)
            except ValueError:
                warnings.append(f"{nid}: propriedades do ANA ilegíveis, ignoradas")
        typ = props.pop("ana_type", None)
        if not typ:
            if tag == "intermediateCatchEvent":
                if el.find("bpmn:timerEventDefinition", NS) is not None:
                    typ = "timer"
                    dur = el.findtext("bpmn:timerEventDefinition/bpmn:timeDuration", default="", namespaces=NS)
                    m = re.match(r"PT(\d+(?:\.\d+)?)H", dur or "")
                    props["hours"] = float(m.group(1)) if m else 1
                elif el.find("bpmn:conditionalEventDefinition", NS) is not None:
                    typ = "event_fact"
                    props["fact"] = el.findtext("bpmn:conditionalEventDefinition/bpmn:condition", default="", namespaces=NS)
            else:
                typ = FROM_BPMN.get(tag)
        if not typ:
            warnings.append(f"elemento não suportado: {tag} \"{el.get('name') or nid}\" — não importado")
            continue
        x, y = bounds.get(nid, (80 + 170 * col, 120))
        col += 1
        name = el.get("name") or (el.findtext("bpmn:text", default="", namespaces=NS) if typ == "annotation" else "") or nid
        nodes.append({"id": safe_id(nid), "type": typ, "name": name, "x": x, "y": y, "lane": lane_of.get(nid), "props": props})
        for sub in el:
            st = sub.tag.split("}")[-1]
            if st.endswith("EventDefinition") and st not in ("timerEventDefinition", "conditionalEventDefinition"):
                warnings.append(f"{nid}: {st} não suportado — tratado como elemento simples")
    ids = {n["id"] for n in nodes}
    defaults = {el.get("default") for el in proc if el.get("default")}
    for f in proc.findall("bpmn:sequenceFlow", NS):
        a, b = safe_id(f.get("sourceRef")), safe_id(f.get("targetRef"))
        if a not in ids or b not in ids:
            warnings.append(f"ligação {f.get('id')} aponta para elemento não importado — removida")
            continue
        e = {"id": safe_id(f.get("id")), "from": a, "to": b}
        if f.get("name"):
            e["name"] = f.get("name")
        raw = f.get(q("condition", "ana"))
        if raw:
            try:
                e.update(json.loads(raw))
            except ValueError:
                pass
        elif f.find("bpmn:conditionExpression", NS) is not None:
            warnings.append(f"ligação {f.get('id')}: condição em linguagem externa — refaça com o construtor de condições")
        if f.get("id") in defaults:
            e["default"] = True
        edges.append(e)
    for n in nodes:
        if n["lane"] is None and lanes:
            n["lane"] = lanes[0]["id"]
    if not lanes:
        lanes = [{"id": "l1", "name": "Responsável", "role": "user"}]
        for n in nodes:
            n["lane"] = "l1"
    meta = {}
    try:
        meta = json.loads(proc.get(q("props", "ana")) or "{}")
    except ValueError:
        warnings.append("propriedades do processo ilegíveis, ignoradas")
    model = {"document": meta.get("document") or "none", "run_as": meta.get("run_as") or "system", "lanes": lanes,
             "variables": meta.get("variables") or [], "nodes": nodes, "edges": edges}
    result = {"model": model, "warnings": warnings, "issues": common.validate(model, code)}
    if code:
        p = ana.sql_one("SELECT flow_code FROM bpm.process WHERE code = $1", code)
        if not p:
            raise ana.Error("PROCESS_NOT_FOUND", f"crie o processo {code} no mapa antes de importar")
        r = ana.call("bpm.save_model", process=code, model=model)
        result["version"] = r["version"]
    return result


def safe_id(v):
    v = re.sub(r"[^A-Za-z0-9_-]", "_", str(v or "x"))
    v = v if re.match(r"^[A-Za-z]", v) else "n" + v
    return v[:40]
