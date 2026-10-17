# ana:description Processos: inicia um caso de um processo publicado (avulso ou seguindo um documento do ERP)
# ana:exposed yes
"""Spec 039 (RF-039-11). Processes started by a document start by themselves when the document is created;
this program starts the others (and lets integrations start any)."""

from ana_lib.bpm import common

PARAMS = {"process": {"type": "str", "required": True, "label": "processo"},
          "document": {"type": "str", "label": "chave do documento (pedido, OS, projeto…)"},
          "title": {"type": "str", "label": "título do caso"},
          "data": {"type": "dict", "label": "dados iniciais"}}


def main(process, document=None, title=None, data=None):
    p = common.process(process)
    if p["flow_code"]:
        raise ana.Error("READ_ONLY", "esteira: começa sozinha com o documento (ligue-a em Esteiras)")
    if not p["active"]:
        raise ana.Error("INVALID_STATE", "processo inativo")
    v = common.version(process, "published")
    if not v:
        raise ana.Error("NOT_PUBLISHED", "publique o processo antes de iniciar casos")
    entity = v["model"].get("document") or "none"
    if entity != "none" and not document:
        raise ana.Error("INVALID_PARAMETER", "informe o documento que o caso segue")
    if entity != "none":
        facts = ana.sql_value("SELECT facts_sql FROM bpm.document WHERE entity = $1", entity)
        if not ana.sql(facts, str(document)):
            raise ana.Error("NOT_FOUND", f"documento {document} não encontrado")
    start = v["compiled"]["start"]
    cid = ana.sql_value("INSERT INTO bpm.case (process_code, version, doc_entity, doc_key, title, data, started_by) "
                        "VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id", process, v["version"], entity,
                        str(document) if document else None, (title or f"{p['name']}" + (f" — {document}" if document else ""))[:200],
                        data or {}, ana.context.user)
    tok = ana.sql_value("INSERT INTO bpm.token (case_id, node) VALUES ($1, $2) RETURNING id", cid, start)
    ana.sql_exec("INSERT INTO bpm.task (case_id, token_id, node, kind, name, status, how, finished_at) "
                 "VALUES ($1, $2, $3, 'rule', 'Início', 'done', 'auto', now())", cid, tok, start)
    ana.sql_exec("INSERT INTO bpm.event (case_id, node, kind, by) VALUES ($1, $2, 'start', $3)", cid, start, ana.context.user)
    return {"case": cid, "process": process, "version": v["version"]}
