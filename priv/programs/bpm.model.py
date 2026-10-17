# ana:description Processos: modelo de um processo (rascunho ou versão), com a validação e as opções para o editor
# ana:exposed yes
"""Spec 039 (RF-039-02..04). version: a number, "draft", "published" or empty (draft, else published)."""

from ana_lib.bpm import common
from ana_lib.bpm import templates

PARAMS = {"process": {"type": "str", "required": True, "label": "processo"},
          "version": {"type": "str", "label": "versão"}}


def main(process, version=None):
    p = common.process(process)
    v = common.version(process, version or None)
    if not v:
        raise ana.Error("NOT_FOUND", "versão não encontrada")
    versions = ana.sql("SELECT version, status, comment, created_by, created_at, published_by, published_at, retired_at "
                       "FROM bpm.version WHERE process_code = $1 ORDER BY version DESC", process)
    return {"process": p, "version": v["version"], "status": v["status"], "model": v["model"], "sim": v["sim"],
            "updated_at": v["updated_at"], "issues": [] if p["flow_code"] else common.validate(v["model"], process), "versions": versions,
            "editable": v["status"] == "draft" and common.can_design() and not p["flow_code"],
            "can_publish": common.can_publish(p) and not p["flow_code"],
            "options": options()}


def options():
    """Choices offered by the property panel: programs, facts, documents, processes, roles and groups."""
    return {
        "types": [{"type": k, **v} for k, v in common.TYPES.items()],
        "programs": [r["n"] for r in ana.sql("SELECT n FROM bpm.program_names() AS n")],
        "facts": ana.sql("SELECT code, entity, name FROM bpm.fact ORDER BY entity, code"),
        "documents": ana.sql("SELECT entity, label FROM bpm.document ORDER BY label"),
        "processes": ana.sql("SELECT code, name FROM bpm.process WHERE flow_code IS NULL ORDER BY name"),
        "groups": [r["n"] for r in ana.sql("SELECT n FROM bpm.group_names() AS n")],
        "roles": [["user", "Usuário"], ["developer", "Desenvolvedor"], ["admin", "Administrador"]],
        "templates": [{"code": t["code"], "name": t["name"], "description": t["description"]} for t in templates.TEMPLATES],
    }
