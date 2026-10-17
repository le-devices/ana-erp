# ana:description Processos: grava o rascunho do modelo (desenho), com a validação; publicada nunca muda
# ana:exposed yes
"""Spec 039 (RF-039-02, 03, 06). Saving always works for a draft (even with errors: they block only the
publication). base_updated_at protects against overwriting someone else's edit."""

import json

from ana_lib.bpm import common

PARAMS = {"process": {"type": "str", "required": True, "label": "processo"},
          "model": {"type": "dict", "required": True, "label": "modelo"},
          "sim": {"type": "dict", "label": "parâmetros de simulação"},
          "base_updated_at": {"type": "str", "label": "versão lida (data)"}}
MAX_BYTES = 2_000_000


def main(process, model, sim=None, base_updated_at=None):
    common.require_design()
    p = common.process(process, lock=True)
    if p["flow_code"]:
        raise ana.Error("READ_ONLY", "esteira: configure modos, condições e robô em Esteiras")
    if len(json.dumps(model)) > MAX_BYTES:
        raise ana.Error("TOO_LARGE", "modelo grande demais: divida em subprocessos")
    if len(model.get("nodes") or []) > 300:
        raise ana.Error("TOO_LARGE", "no máximo 300 elementos por processo: use subprocessos")
    d = common.version(process, "draft")
    if d is None:
        last = common.version(process, "published") or common.version(process)
        n = (ana.sql_value("SELECT max(version) FROM bpm.version WHERE process_code = $1", process) or 0) + 1
        ana.sql_exec("INSERT INTO bpm.version (process_code, version, model, sim, created_by) VALUES ($1, $2, $3, $4, $5)",
                     process, n, model, sim if sim is not None else (last["sim"] if last else {}), ana.context.user)
    else:
        if base_updated_at and str(d["updated_at"])[:23] != str(base_updated_at)[:23]:
            raise ana.Error("CONFLICT", "outra pessoa salvou o rascunho depois que você o abriu: recarregue para não perder a alteração dela")
        ana.sql_exec("UPDATE bpm.version SET model = $3, sim = COALESCE($4, sim), updated_at = now() "
                     "WHERE process_code = $1 AND version = $2", process, d["version"], model, sim)
    v = common.version(process, "draft")
    return {"version": v["version"], "updated_at": v["updated_at"], "issues": common.validate(model, process)}
