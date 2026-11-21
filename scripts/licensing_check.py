#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 LE Devices
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Licensing checks of the repository (spec 066, T-066-02 and T-066-05), run by the battery on every pull request.

    licensing_check.py headers           every source file carries the SPDX lines (or is covered by REUSE.toml)
    licensing_check.py deps              every dependency in rebar.lock has a license from the accepted list
    licensing_check.py secrets BASE      no credential in the lines added since BASE (a commit or branch)
    licensing_check.py all [BASE]        the three (secrets only when BASE is given)
    licensing_check.py add-headers       writes the SPDX lines into the source files that miss them

Uses only the standard library and git: it runs before anything is installed.
"""
import fnmatch
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LICENSE_ID = "AGPL-3.0-or-later"
HOLDER = "2026 LE Devices"
SPDX = "SPDX-License-Identifier:"

# How each kind of file comments a line (prefix, suffix). Files not listed here are covered by REUSE.toml.
STYLES = {
    ".erl": ("%% ", ""), ".hrl": ("%% ", ""), ".app.src": ("%% ", ""), ".config": ("%% ", ""),
    ".py": ("# ", ""), ".sh": ("# ", ""), ".yml": ("# ", ""), ".yaml": ("# ", ""), ".cfg": ("# ", ""),
    ".args": ("# ", ""), ".js": ("// ", ""), ".mjs": ("// ", ""), ".css": ("/* ", " */"),
    ".html": ("<!-- ", " -->"), ".sql": ("-- ", ""),
}
NAMED = {"Dockerfile": ("# ", ""), "Makefile": ("# ", ""), "Caddyfile": ("# ", ""), "rebar.config": ("%% ", ""),
         "bin/ana-start": ("# ", ""), "deploy/ana-ctl": ("# ", ""), ".gitignore": ("# ", ""),
         ".dockerignore": ("# ", ""), ".github/battery-plan.sh": ("# ", "")}
# Covered by REUSE.toml instead of a header in each file (see the reasons there): the product programs (a header
# would offer every installation ~260 "product updates" for a comment), the migrations (never edited once applied),
# the demonstration data.
BY_REUSE = ["priv/programs/*", "priv/migrations/*", "priv/demo/*"]
HEAD_LINES = 6

# Dependencies shipped with the core and their licenses (checked against rebar.lock). A new dependency is added
# here only after its license is read; licenses outside ACCEPTED are refused.
ACCEPTED = {"Apache-2.0", "MIT", "ISC", "BSD-2-Clause", "BSD-3-Clause", "MPL-2.0", "AGPL-3.0-or-later",
            "AGPL-3.0-only", "LGPL-2.1-or-later", "LGPL-3.0-or-later", "PostgreSQL", "Python-2.0", "Zlib"}
DEPENDENCIES = {"cowboy": "ISC", "cowlib": "ISC", "ranch": "ISC", "epgsql": "BSD-3-Clause"}

# Credentials of known services, private keys and assignments of long literal secrets.
SECRET_PATTERNS = [
    ("chave privada", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----")),
    ("chave da AWS", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("token do GitHub", re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{40,}")),
    ("token do Slack", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("chave de API de IA", re.compile(r"\bsk-(?:ant-)?[A-Za-z0-9_-]{32,}")),
    ("chave do Google", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("chave de pagamento", re.compile(r"\b(?:sk|rk)_live_[A-Za-z0-9]{20,}")),
    ("JWT", re.compile(r"\beyJ[A-Za-z0-9_-]{20,}\.eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}")),
]
# Known on purpose: the test key of licenses (signs only non-production licenses, spec 009 D2) and the fake
# credentials the tests use to check that credentials are refused.
SECRET_ALLOWED_PATHS = {"tests/integration/license_test.key"}
SECRET_ALLOWED_TEXT = ["sk_live_abcdefgh12345678", '"-----BEGIN PRIVATE KEY-----\\nabc"']


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


def tracked():
    return [f for f in git("ls-files", "-z").split("\0") if f]


def style_of(path):
    if path in NAMED or os.path.basename(path) in NAMED:
        return NAMED.get(path) or NAMED[os.path.basename(path)]
    if path.endswith(".app.src"):
        return STYLES[".app.src"]
    return STYLES.get(os.path.splitext(path)[1])


def needs_header(path):
    return style_of(path) is not None and not any(fnmatch.fnmatch(path, p) for p in BY_REUSE)


def has_header(path):
    with open(os.path.join(ROOT, path), encoding="utf-8", errors="replace") as f:
        head = [next(f, "") for _ in range(HEAD_LINES)]
    return any(SPDX in line and LICENSE_ID in line for line in head)


def headers():
    missing = [p for p in tracked() if needs_header(p) and os.path.exists(os.path.join(ROOT, p)) and not has_header(p)]
    for p in missing:
        print(f"::error file={p}::sem as linhas SPDX ({SPDX} {LICENSE_ID}): rode scripts/licensing_check.py add-headers")
    print(f"cabeçalhos de licença: {len(missing)} arquivo(s) sem as linhas SPDX" if missing else "cabeçalhos de licença: ok")
    return not missing


def add_headers():
    done = 0
    for p in tracked():
        full = os.path.join(ROOT, p)
        if not needs_header(p) or not os.path.exists(full) or has_header(p):
            continue
        pre, post = style_of(p)
        with open(full, encoding="utf-8") as f:
            lines = f.read().split("\n")
        block = [f"{pre}SPDX-FileCopyrightText: {HOLDER}{post}", f"{pre}{SPDX} {LICENSE_ID}{post}"]
        # After a shebang or an HTML doctype; at the top otherwise.
        at = 1 if lines and (lines[0].startswith("#!") or lines[0].lower().startswith("<!doctype")) else 0
        lines[at:at] = block
        with open(full, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
        done += 1
    print(f"linhas SPDX escritas em {done} arquivo(s)")
    return True


def deps():
    lock = open(os.path.join(ROOT, "rebar.lock"), encoding="utf-8").read()
    names = sorted(set(re.findall(r'\{<<"([a-z0-9_]+)">>,\{pkg,', lock)))
    ok = True
    for n in names:
        lic = DEPENDENCIES.get(n)
        if lic is None:
            print(f"::error file=rebar.lock::dependência {n} sem licença conferida: leia a licença e inclua em "
                  "DEPENDENCIES (scripts/licensing_check.py) e no NOTICE")
            ok = False
        elif lic not in ACCEPTED:
            print(f"::error file=rebar.lock::dependência {n} com licença {lic}, fora das aceitas")
            ok = False
    listed = ", ".join("%s (%s)" % (n, DEPENDENCIES.get(n, "?")) for n in names)
    print(f"licenças das dependências: {listed}")
    return ok


def secrets(base):
    diff = git("diff", "--unified=0", "--no-color", f"{base}...HEAD")
    found, path = [], None
    for line in diff.split("\n"):
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
            continue
        if not line.startswith("+") or path is None or path in SECRET_ALLOWED_PATHS:
            continue
        text = line[1:]
        if any(a in text for a in SECRET_ALLOWED_TEXT):
            continue
        for what, rx in SECRET_PATTERNS:
            if rx.search(text):
                found.append((path, what))
    for p, what in found:
        print(f"::error file={p}::possível credencial ({what}) adicionada: tire do arquivo e troque a credencial")
    print(f"credenciais no que foi adicionado desde {base}: {len(found)}" if found else f"credenciais desde {base}: nenhuma")
    return not found


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "all"
    if cmd == "headers":
        ok = headers()
    elif cmd == "deps":
        ok = deps()
    elif cmd == "secrets" and len(argv) > 2:
        ok = secrets(argv[2])
    elif cmd == "add-headers":
        ok = add_headers()
    elif cmd == "all":
        results = [headers(), deps()] + ([secrets(argv[2])] if len(argv) > 2 else [])
        ok = all(results)
    else:
        print(__doc__)
        return 2
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
