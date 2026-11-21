# SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Test battery and open pull requests from GitHub, for the project dashboard (internal tool).

Read-only: GET requests to api.github.com only, with a fine-grained token that can only read Actions,
pull requests and metadata of this repository. The token comes from a file (never from the repository)
and never appears in the answer. Without a token the band explains how to set it up; any failure is
reported in the band and never breaks the rest of the dashboard.
"""
import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request

API = "https://api.github.com"
CACHE_S = 60          # GitHub allows 5,000 requests per hour; the dashboard makes ~3 per minute
RUNS = 6


class _Cache:
    lock = threading.Lock()
    value = None
    at = 0.0


def slug(repo):
    """owner/name from the origin remote (git@github.com:owner/name.git or https://github.com/owner/name)."""
    try:
        url = subprocess.run(["git", "-c", "safe.directory=*", "-C", repo, "config", "--get", "remote.origin.url"], capture_output=True,
                             text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"github\.com[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?$", url)
    return f"{m.group(1)}/{m.group(2)}" if m else None


def _token(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip() or None
    except OSError:
        return None


def _get(path, token):
    req = urllib.request.Request(API + path, headers={
        "Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "ana-dashboard"})
    with urllib.request.urlopen(req, timeout=8) as r:
        return json.load(r)


def _minutes(a, b):
    if not a or not b:
        return None
    t = lambda s: time.mktime(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
    return max(0, round((t(b) - t(a)) / 60))


def _run(r):
    return {"id": r["id"], "title": r.get("display_title") or r.get("name"), "branch": r.get("head_branch"),
            "sha": (r.get("head_sha") or "")[:7], "event": r.get("event"), "status": r.get("status"),
            "conclusion": r.get("conclusion"), "started": r.get("run_started_at") or r.get("created_at"),
            "minutes": _minutes(r.get("run_started_at"), r.get("updated_at")) if r.get("status") == "completed" else None,
            "url": r.get("html_url")}


def fetch(repo, token_file):
    name = slug(repo)
    if not name:
        return {"configured": False, "reason": "o repositório não tem remoto no GitHub"}
    token = _token(token_file)
    if not token:
        return {"configured": False, "repo": name, "reason": f"sem token de leitura em {token_file}"}
    try:
        runs = [_run(r) for r in _get(f"/repos/{name}/actions/runs?per_page={RUNS}", token).get("workflow_runs", [])]
        jobs = []
        if runs:
            jobs = [{"name": j["name"], "status": j["status"], "conclusion": j.get("conclusion"),
                     "minutes": _minutes(j.get("started_at"), j.get("completed_at"))}
                    for j in _get(f"/repos/{name}/actions/runs/{runs[0]['id']}/jobs?per_page=50", token).get("jobs", [])]
        latest = {}
        for r in runs:                       # newest first: the first run seen for a commit is its current state
            latest.setdefault(r["sha"], r)
        pulls = [{"number": p["number"], "title": p["title"], "head": p["head"]["ref"], "base": p["base"]["ref"],
                  "draft": p.get("draft", False), "url": p["html_url"], "updated": p.get("updated_at"),
                  "battery": latest.get(p["head"]["sha"][:7])}
                 for p in _get(f"/repos/{name}/pulls?state=open&per_page=20", token)]
        return {"configured": True, "repo": name, "runs": runs, "jobs": jobs, "pulls": pulls,
                "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    except urllib.error.HTTPError as e:
        hint = {401: "token inválido ou expirado", 403: "token sem permissão de leitura (Actions e Pull requests)",
                404: "token sem acesso a este repositório"}.get(e.code, f"GitHub respondeu {e.code}")
        return {"configured": True, "repo": name, "error": hint}
    except (urllib.error.URLError, TimeoutError, OSError, ValueError, KeyError) as e:
        return {"configured": True, "repo": name, "error": f"GitHub indisponível ({type(e).__name__})"}


def cached(repo, token_file):
    with _Cache.lock:
        if _Cache.value is None or time.time() - _Cache.at > CACHE_S:
            _Cache.value = fetch(repo, token_file)
            _Cache.at = time.time()
        return _Cache.value


DEFAULT_TOKEN_FILE = os.environ.get("ANA_DASHBOARD_GITHUB_TOKEN_FILE", "/run/secrets/github-token")
