# ana:description Apresentação das diferenças dos casos de teste tributários antes e depois de uma mudança
# ana:kind library
"""Differences of the test cases before × after a change (spec 049, CA-049-04)."""


def show_differences(diffs):
    if diffs:
        ana.table([{"caso": d["name"], "antes": _short(d["before"]), "depois": _short(d["after"]),
                    "esperado": "; ".join(d["expected"]) or "confere"} for d in diffs], title="O que muda nos casos de teste")


def _short(res):
    if not res.get("ok"):
        return "erro: " + res.get("error", "")
    return "; ".join(f"{t} {v.get('amount') or v.get('withheld') or v.get('credit') or '0'}" for t, v in sorted(res["taxes"].items())) or "sem tributos"
