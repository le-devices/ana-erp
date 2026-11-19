"""Project dashboard server (internal tool): GET / (the page) and GET /data.json (fresh numbers).

Read-only: it only reads the repository (files and git history) and answers two fixed paths.
  python3 tools/dashboard/serve.py [--repo PATH] [--port 8099] [--bind 0.0.0.0]
"""
import argparse
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import collect
import github

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE_S = 20


class State:
    lock = threading.Lock()
    data = None
    at = 0.0


def data(repo, token_file):
    with State.lock:
        if State.data is None or time.time() - State.at > CACHE_S:
            d = collect.collect(repo)
            d["ci"] = github.cached(repo, token_file)       # its own 60 s cache; never raises
            State.data = json.dumps(d, ensure_ascii=False).encode("utf-8")
            State.at = time.time()
        return State.data


def handler(repo, token_file):
    class Handler(BaseHTTPRequestHandler):
        def send(self, status, body, ctype):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; "
                                                        "script-src 'self' 'unsafe-inline'; img-src 'self' data:")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path in ("/", "/index.html"):
                with open(os.path.join(HERE, "index.html"), "rb") as f:
                    self.send(200, f.read(), "text/html; charset=utf-8")
            elif path == "/data.json":
                try:
                    self.send(200, data(repo, token_file), "application/json; charset=utf-8")
                except Exception as e:                      # a broken read never takes the server down
                    self.send(500, json.dumps({"error": str(e)}).encode(), "application/json")
            else:
                self.send(404, b"not found", "text/plain")

        def log_message(self, fmt, *args):
            pass

    return Handler


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--repo", default=os.path.abspath(os.path.join(HERE, "..", "..")))
    p.add_argument("--port", type=int, default=int(os.environ.get("DASHBOARD_PORT", "8099")))
    p.add_argument("--bind", default=os.environ.get("DASHBOARD_BIND", "0.0.0.0"))
    p.add_argument("--github-token-file", default=github.DEFAULT_TOKEN_FILE,
                   help="token do GitHub só de leitura (Actions, Pull requests, Metadata)")
    a = p.parse_args()
    print(f"painel em http://{a.bind}:{a.port}/ (repositório {a.repo})", flush=True)
    ThreadingHTTPServer((a.bind, a.port), handler(a.repo, a.github_token_file)).serve_forever()
