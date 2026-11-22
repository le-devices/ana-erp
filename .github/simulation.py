#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Usage simulation in GitHub Actions (spec 067, D6a). Standard library and the gh CLI only.

    simulation.py run --out report.json        starts a run on the local stack (SEED, DAYS, PER_DAY), waits, saves the report
    simulation.py issues --report report.json  prints the job summary (Markdown) and keeps one issue per finding:
                                               opens the new ones, notes the persistent ones, closes the ones gone
Issues carry the label "uso-simulado" and the finding's fingerprint in the title: "[uso simulado] … (abcdef0123456789)".
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

URL = os.environ.get("ANA_URL", "http://localhost:8080")
LABEL = "uso-simulado"
MAX_NEW = 20                                   # never a flood of issues from one bad night
CATEGORY = {"automation": "Automação", "accounts": "Contas", "usability": "Usabilidade", "robustness": "Robustez",
            "performance": "Desempenho", "access": "Acesso"}


def http(method, path, body=None, token=None):
    req = urllib.request.Request(URL + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json", **({"Authorization": "Bearer " + token} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode() or "{}")


def run(out):
    s, login = http("POST", "/api/session", {"username": "admin", "password": os.environ.get("ANA_ADMIN_PASSWORD", "admin")})
    token = login["token"]
    body = {"days": int(os.environ.get("DAYS") or 3), "per_day": int(os.environ.get("PER_DAY") or 12), "flows": True}
    if os.environ.get("SEED"):
        body["seed"] = int(os.environ["SEED"])
    s, started = http("POST", "/api/admin/simulation/run", body, token)
    if s != 200:
        sys.exit(f"a simulação não começou: {started}")
    print(f"simulação {started['id']}, semente {started['seed']}", flush=True)
    deadline = time.time() + 4.5 * 3600
    while True:
        s, rep = http("GET", f"/api/admin/simulation/runs/{started['id']}", token=token)
        if rep.get("status") != "running" or time.time() > deadline:
            break
        time.sleep(15)
    rep.pop("steps", None)                      # the full log stays in the instance; the report keeps the findings
    with open(out, "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1)
    print(f"situação: {rep.get('status')}; achados: {len(rep.get('findings', []))}")
    if rep.get("status") not in ("done",):
        sys.exit(1)


def gh(*args, input_text=None):
    r = subprocess.run(["gh", *args], capture_output=True, text=True, input=input_text)
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
    return r.stdout


def issues(report):
    rep = json.load(open(report, encoding="utf-8"))
    findings = rep.get("findings", [])
    repo, run_url = os.environ["REPO"], os.environ.get("RUN_URL", "")
    gh("label", "create", LABEL, "--repo", repo, "--color", "B60205", "--description", "Achado do uso simulado (spec 067)")
    opened = json.loads(gh("issue", "list", "--repo", repo, "--label", LABEL, "--state", "open", "--limit", "500",
                           "--json", "number,title") or "[]")
    by_fp = {m.group(1): i["number"] for i in opened for m in [re.search(r"\(([0-9a-f]{16})\)$", i["title"])] if m}
    seen, created = set(), 0
    for f in findings:
        fp = f["fingerprint"]
        seen.add(fp)
        steps = "\n".join(f"{n + 1}. `{s['persona']}`: `{s['program']}` `{json.dumps(s.get('params'), ensure_ascii=False)[:300]}` → "
                          f"{'ok' if s.get('ok') else s.get('code') or 'falhou'}{' (erro humano)' if s.get('mistake') else ''}"
                          for n, s in enumerate(f.get("steps") or []))
        body = (f"**{CATEGORY.get(f['category'], f['category'])}** · {f['severity']} · cenário `{f.get('scenario') or '—'}` · "
                f"persona `{f.get('persona') or '—'}`\n\nSemente **{f['seed']}** — reproduza com *Run workflow* → semente {f['seed']}.\n\n"
                f"Detalhe:\n```json\n{json.dumps(f.get('detail'), ensure_ascii=False, indent=1)[:3000]}\n```\n\n"
                + (f"Passos:\n{steps}\n\n" if steps else "") + f"Execução: {run_url}\n\n_Dados só de demonstração (repositório público)._")
        if fp in by_fp:
            gh("issue", "comment", str(by_fp[fp]), "--repo", repo, "--body", f"Visto de novo em {run_url} (semente {f['seed']}).")
        elif created < MAX_NEW:
            gh("issue", "create", "--repo", repo, "--label", LABEL, "--title", f"[uso simulado] {f['title'][:180]} ({fp})",
               "--body-file", "-", input_text=body)
            created += 1
    if rep.get("status") == "done":
        for fp, number in by_fp.items():
            if fp not in seen:
                gh("issue", "close", str(number), "--repo", repo, "--comment", f"Não apareceu mais em {run_url}: resolvido.")
    print(f"## Uso simulado — rodada {rep.get('id')} (semente {rep.get('seed')})\n")
    st = rep.get("stats") or {}
    print(f"Situação: **{rep.get('status')}** · {st.get('steps', 0)} passos em {st.get('scenarios', 0)} cenários · "
          f"{st.get('mistakes', 0)} erros humanos simulados · {len(findings)} achado(s), {created} issue(s) nova(s)\n")
    for f in findings:
        print(f"- **{CATEGORY.get(f['category'], f['category'])}**: {f['title']} (`{f['fingerprint']}`)")


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "run":
        run(sys.argv[sys.argv.index("--out") + 1])
    elif len(sys.argv) >= 2 and sys.argv[1] == "issues":
        issues(sys.argv[sys.argv.index("--report") + 1])
    else:
        print(__doc__)
        sys.exit(2)
