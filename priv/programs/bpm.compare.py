# ana:description Processos: o que mudou entre duas versões de um processo (elementos e ligações acrescentados, removidos, alterados)
# ana:exposed yes
"""Spec 039 (RF-039-06, H9). The screen paints the difference on the diagram."""

from ana_lib.bpm import common

PARAMS = {"process": {"type": "str", "required": True, "label": "processo"},
          "a": {"type": "str", "required": True, "label": "versão antiga"},
          "b": {"type": "str", "required": True, "label": "versão nova"}}
VISUAL = {"x", "y", "w", "h"}


def main(process, a, b):
    va, vb = common.version(process, a), common.version(process, b)
    if not va or not vb:
        raise ana.Error("NOT_FOUND", "versão não encontrada")
    out = {"process": process, "a": va["version"], "b": vb["version"]}
    for kind in ("nodes", "edges", "lanes"):
        old = {x["id"]: x for x in va["model"].get(kind) or []}
        new = {x["id"]: x for x in vb["model"].get(kind) or []}
        out[kind] = {
            "added": sorted(set(new) - set(old)),
            "removed": sorted(set(old) - set(new)),
            "changed": sorted(k for k in set(old) & set(new)
                              if {x: y for x, y in old[k].items() if x not in VISUAL} != {x: y for x, y in new[k].items() if x not in VISUAL}),
            "moved": sorted(k for k in set(old) & set(new)
                            if any(old[k].get(x) != new[k].get(x) for x in VISUAL)),
        }
    out["summary"] = ", ".join(f"{len(out[k][w])} {lbl} {w2}" for k, lbl in (("nodes", "elemento(s)"), ("edges", "ligação(ões)"))
                               for w, w2 in (("added", "novo(s)"), ("removed", "removido(s)"), ("changed", "alterado(s)"))
                               if out[k][w]) or "sem diferença de conteúdo"
    return out
