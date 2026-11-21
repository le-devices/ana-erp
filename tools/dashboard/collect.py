# SPDX-FileCopyrightText: 2026 LE Devices
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Project dashboard data (internal tool, not part of the product).

Everything comes from the repository itself, read at request time:
  specs/README.md               specs, titles and status
  specs/NNN-*/spec.md           requirements (RF/RNF/CA ids)
  specs/NNN-*/tasks.md          tasks done / pending
  scripts/pending-work.prompt.md  the agreed queue ("Fila atual")
  git history                   when each task was checked, commits and lines per spec, activity
  tests/, test/                 tests that cite each spec
"""
import collections
import datetime as dt
import glob
import os
import re
import subprocess

TASK = re.compile(r"^- \[( |x)\] (T-(\d{3})-\d+[a-z]?)\s+(.*)$")
TASK_ADDED = re.compile(r"^\+- \[( |x)\] (T-\d{3}-\d+[a-z]?)\b")
SPEC_ROW = re.compile(r"^\| (\d{3}) \| \[([^\]]+)\]\(([^)]+)\) \| (.*?) \| (.*?) \|\s*$")
REQ = re.compile(r"\*\*((?:RF|RNF|CA)-(\d{3})-[0-9a-z]+)\*\*")
SPEC_REF = re.compile(r"(?:[Ss]pecs? |T-|feature/|bugfix/)(\d{3})")
TEST_PY = re.compile(r"def test_(?:ca|rf|rnf|t)_(\d{3})_")
TEST_ERL = re.compile(r"^t_(\d{3})_\w*_test\(\)", re.M)
EXT = {".erl": "Erlang", ".py": "Python", ".js": "JavaScript", ".sql": "SQL", ".css": "CSS", ".html": "HTML", ".mjs": "JavaScript"}


def git(repo, *args):
    return subprocess.run(["git", "-c", "safe.directory=*", "-C", repo, *args], capture_output=True, text=True,
                          check=True).stdout


def day(iso):
    return iso[:10]


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def specs_index(repo):
    out = {}
    for line in read(os.path.join(repo, "specs", "README.md")).splitlines():
        m = SPEC_ROW.match(line)
        if m and m.group(1) != "000":                     # 000 is the constitution, not a feature
            num, title, link, desc, status = m.groups()
            out[num] = {"id": num, "title": title, "dir": os.path.dirname(link), "summary": desc.strip(),
                        "status_text": status.strip()}
    return out


def status_of(text, done, total):
    t = text.lower()
    if t.startswith("especificada"):
        return "specified"
    if total and done == total:
        return "done"
    if "implementada" in t:
        return "partial" if done < total else "done"
    return "specified" if done == 0 else "partial"


def tasks_of(repo, d):
    tasks = []
    phase = None
    for line in read(os.path.join(repo, "specs", d, "tasks.md")).splitlines():
        m = TASK.match(line.strip())
        if m:
            done, tid, _, text = m.groups()
            tasks.append({"id": tid, "done": done == "x", "text": text.strip(), "deferred": bool(re.search(r"\d[a-z]$", tid)),
                          "phase": phase})
        elif line.strip() and not line.startswith("#") and not line.startswith("-"):
            phase = line.strip()
    return tasks


def task_history(repo):
    """First time each task id appeared in a tasks.md, and first time it was checked."""
    created, finished = {}, {}
    when = None
    log = git(repo, "log", "--reverse", "--format=@@%aI", "-p", "-U0", "--", "specs/*/tasks.md")
    for line in log.splitlines():
        if line.startswith("@@") and not line.startswith("@@ "):
            when = line[2:]
            continue
        m = TASK_ADDED.match(line)
        if m and when:
            created.setdefault(m.group(2), when)
            if m.group(1) == "x":
                finished.setdefault(m.group(2), when)
    return created, finished


def commit_stats(repo):
    """Per spec: commits, lines added/removed, files, first/last date, active days; plus weekly activity."""
    per = collections.defaultdict(lambda: {"commits": 0, "added": 0, "removed": 0, "files": set(), "days": set(),
                                           "first": None, "last": None})
    weekly = collections.Counter()
    recent = []
    cur = None
    log = git(repo, "log", "--reverse", "--no-merges", "--format=@@%H%x09%aI%x09%s", "--numstat")
    for line in log.splitlines():
        if line.startswith("@@"):
            h, when, subject = line[2:].split("\t", 2)
            nums = sorted(set(SPEC_REF.findall(subject)))
            cur = (when, nums)
            d = dt.date.fromisoformat(day(when))
            weekly[(d - dt.timedelta(days=d.weekday())).isoformat()] += 1
            recent.append({"hash": h[:7], "date": when, "subject": subject, "specs": nums})
            for n in nums:
                p = per[n]
                p["commits"] += 1
                p["days"].add(day(when))
                p["first"] = p["first"] or when
                p["last"] = when
            continue
        parts = line.split("\t")
        if cur and len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            for n in cur[1]:
                per[n]["added"] += int(parts[0])
                per[n]["removed"] += int(parts[1])
                per[n]["files"].add(parts[2])
    return per, weekly, recent[-20:][::-1]


def tests_per_spec(repo):
    count = collections.Counter()
    for path in glob.glob(os.path.join(repo, "tests", "**", "*.py"), recursive=True):
        for n in TEST_PY.findall(read(path)):
            count[n] += 1
    for path in glob.glob(os.path.join(repo, "test", "*.erl")):
        for n in TEST_ERL.findall(read(path)):
            count[n] += 1
    return count


def code_size(repo):
    size = collections.Counter()
    files = git(repo, "ls-files").splitlines()
    for f in files:
        lang = EXT.get(os.path.splitext(f)[1])
        if lang and not f.startswith("tools/"):
            size[lang] += read(os.path.join(repo, f)).count("\n")
    return dict(size.most_common()), len(glob.glob(os.path.join(repo, "priv", "migrations", "*.sql"))), \
        len(glob.glob(os.path.join(repo, "priv", "programs", "*.py")))


def queue(repo):
    """The agreed queue: numbered lines of the "Fila atual" block."""
    text = read(os.path.join(repo, "scripts", "pending-work.prompt.md"))
    i = text.find("**Fila atual")
    if i < 0:
        return []
    out = []
    for line in text[i:].splitlines()[1:]:
        m = re.match(r"^(\d+)\. (✓ )?(.*)$", line.strip())
        if m:
            item = m.group(3)
            out.append({"pos": int(m.group(1)), "done": bool(m.group(2)), "text": re.sub(r"`", "", item)})
        elif out and not line.strip():
            break
    return out


def complexity(reqs, ntasks, lines):
    """A rough, explainable score: requirements + 2 × tasks + changed lines / 400."""
    score = reqs + 2 * ntasks + lines / 400
    return round(score), ("G" if score >= 90 else "M" if score >= 40 else "P")


def collect(repo):
    index = specs_index(repo)
    created, finished = task_history(repo)
    per, weekly, recent = commit_stats(repo)
    tests = tests_per_spec(repo)
    size, migrations, programs = code_size(repo)
    specs = []
    all_tasks = []
    for num, s in sorted(index.items()):
        d = s["dir"]
        tasks = tasks_of(repo, d)
        for t in tasks:
            t["spec"] = num
            t["created"] = created.get(t["id"])
            t["finished"] = finished.get(t["id"]) if t["done"] else None
        all_tasks += tasks
        reqs = sorted(set(m[0] for m in REQ.findall(read(os.path.join(repo, "specs", d, "spec.md")))))
        c = per.get(num)
        lines = (c["added"] + c["removed"]) if c else 0
        done = sum(t["done"] for t in tasks)
        score, size_class = complexity(len(reqs), len(tasks), lines)
        first = c["first"] if c else None
        last = c["last"] if c else None
        span = (dt.date.fromisoformat(day(last)) - dt.date.fromisoformat(day(first))).days + 1 if first else None
        specs.append({**s, "status": status_of(s["status_text"], done, len(tasks)), "tasks_total": len(tasks),
                      "tasks_done": done, "deferred_pending": sum(1 for t in tasks if not t["done"] and t["deferred"]),
                      "requirements": len(reqs), "tests": tests.get(num, 0),
                      "commits": c["commits"] if c else 0, "lines": lines, "files": len(c["files"]) if c else 0,
                      "active_days": len(c["days"]) if c else 0, "span_days": span, "first": first, "last": last,
                      "complexity": score, "size": size_class})
    # Burn-up: per day, tasks known and tasks done (cumulative).
    days = sorted({day(t["created"]) for t in all_tasks if t["created"]} | {day(t["finished"]) for t in all_tasks if t["finished"]})
    burn = []
    for d in days:
        burn.append({"date": d, "total": sum(1 for t in all_tasks if t["created"] and day(t["created"]) <= d),
                     "done": sum(1 for t in all_tasks if t["finished"] and day(t["finished"]) <= d)})
    done_dates = sorted(day(t["finished"]) for t in all_tasks if t["finished"])
    today = dt.date.today()
    last14 = sum(1 for d in done_dates if (today - dt.date.fromisoformat(d)).days < 14)
    pending = [t for t in all_tasks if not t["done"]]
    measured = [s for s in specs if s["status"] == "done" and s["active_days"]]
    return {
        "generated_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "head": git(repo, "rev-parse", "--short", "HEAD").strip(),
        "branch": git(repo, "rev-parse", "--abbrev-ref", "HEAD").strip(),
        "summary": {
            "specs": len(specs), "specs_done": sum(s["status"] == "done" for s in specs),
            "specs_partial": sum(s["status"] == "partial" for s in specs),
            "specs_specified": sum(s["status"] == "specified" for s in specs),
            "tasks": len(all_tasks), "tasks_done": sum(t["done"] for t in all_tasks), "tasks_pending": len(pending),
            "tasks_deferred_pending": sum(1 for t in pending if t["deferred"]),
            "done_last_14d": last14, "per_week": round(last14 / 2, 1),
            "weeks_to_finish": round(len(pending) / (last14 / 2), 1) if last14 else None,
            "commits": sum(weekly.values()), "first_commit": min(weekly) if weekly else None,
            "median_active_days": sorted(s["active_days"] for s in measured)[len(measured) // 2] if measured else None,
            "tests": sum(tests.values()), "migrations": migrations, "programs": programs,
        },
        "code": size,
        "specs": specs,
        "pending": [{k: t[k] for k in ("id", "spec", "text", "deferred", "created")} for t in pending],
        "burnup": burn,
        "weekly": [{"week": w, "commits": n} for w, n in sorted(weekly.items())],
        "recent": recent,
        "queue": queue(repo),
    }


if __name__ == "__main__":
    import json
    import sys
    print(json.dumps(collect(sys.argv[1] if len(sys.argv) > 1 else "."), ensure_ascii=False, indent=1)[:3000])
