# ana:description Processos: publica o rascunho (passa a valer para casos novos); a versão anterior é aposentada
# ana:exposed yes
# ana:category Processos/Modelagem
"""Spec 039 (RF-039-06). Only without errors. Running cases keep their version (bpm.migrate moves them on purpose)."""

from ana_lib.bpm import common

PARAMS = {"process": {"type": "str", "required": True, "label": "processo"},
          "comment": {"type": "str", "label": "o que mudou"}}


def main(process, comment=None):
    p = common.process(process, lock=True)
    if not common.can_publish(p):
        raise ana.Error("FORBIDDEN", "publicar exige o administrador ou o dono do processo")
    if p["flow_code"]:
        raise ana.Error("READ_ONLY", "esteira: configure em Esteiras")
    d = common.version(process, "draft")
    if not d:
        raise ana.Error("NOTHING_TO_PUBLISH", "não há rascunho para publicar")
    errs = common.errors(common.validate(d["model"], process))
    if errs:
        raise ana.Error("INVALID_MODEL", f"o modelo tem {len(errs)} erro(s): corrija antes de publicar", {"issues": errs})
    ana.sql_exec("UPDATE bpm.version SET status = 'retired', retired_at = now() WHERE process_code = $1 AND status = 'published'",
                 process)
    ana.sql_exec("UPDATE bpm.version SET status = 'published', compiled = $3, comment = COALESCE($4, comment), "
                 "published_by = $5, published_at = now() WHERE process_code = $1 AND version = $2",
                 process, d["version"], common.compile_model(d["model"]), comment, ana.context.user)
    running = ana.sql_value("SELECT count(*) FROM bpm.case WHERE process_code = $1 AND status IN ('running', 'waiting', 'failed') "
                            "AND version <> $2", process, d["version"])
    return {"process": process, "version": d["version"], "running_old": running}
