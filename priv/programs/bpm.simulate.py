# ana:description Processos: simula um processo (chegadas, durações, caminhos, pessoas e custo) e guarda o cenário para comparar
# ana:exposed yes
"""Spec 039 (RF-039-08, 09, CA-039-04). params (all optional): days, hours_per_day, arrivals_per_day, runs,
seed, resources {lane: {count, cost_hour}}, durations {node: {dist, ...}}, probabilities {edge: p},
fixed_cost {node: value}, automate [node]. Without params: the ones saved with the model. save=True keeps
the scenario (name) in the process's list for comparison."""

from ana_lib.bpm import common
from ana_lib.bpm import sim

PARAMS = {
    "process": {"type": "str", "required": True, "label": "processo"},
    "version": {"type": "str", "label": "versão (vazio = rascunho ou publicada)"},
    "params": {"type": "dict", "label": "parâmetros"},
    "name": {"type": "str", "label": "nome do cenário"},
    "save": {"type": "bool", "default": False, "label": "guardar o cenário"},
}


def main(process, version=None, params=None, name=None, save=False):
    common.process(process)
    v = common.version(process, version or None)
    if not v:
        raise ana.Error("NOT_FOUND", "versão não encontrada")
    errs = [i for i in common.validate(v["model"], process) if i["level"] == "error" and "programa" not in i["message"]]
    if errs:
        raise ana.Error("INVALID_MODEL", f"o modelo tem {len(errs)} erro(s) de estrutura: corrija para simular", {"issues": errs})
    p = dict(v["sim"] or {})
    p.update(params or {})
    try:
        result = sim.simulate(v["model"], common.compile_model(v["model"])["reach"], p)
    except (ValueError, KeyError, TypeError) as e:
        raise ana.Error("INVALID_PARAMETER", f"parâmetros de simulação: {e}") from None
    sid = None
    if save:
        sid = ana.sql_value("INSERT INTO bpm.simulation (process_code, version, name, params, result, seed, created_by) "
                            "VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id", process, v["version"],
                            (name or "cenário").strip()[:80], p, {k: x for k, x in result.items() if k != "trace"},
                            int(p.get("seed", 42)), ana.context.user)
    return {"process": process, "version": v["version"], "params": p, "result": result, "id": sid}
