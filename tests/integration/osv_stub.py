# SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
# SPDX-License-Identifier: AGPL-3.0-or-later
"""A stand-in OSV service for the T-033-09b tests, standard library only.

GET  /feed.json       -> the file /w/osv_feed.json (a list of advisories)
POST /v1/querybatch   -> {"results": [...]}: the id in /w/osv_query_id.txt for package "cowboy", nothing for others
GET  /v1/vulns/<id>   -> the file /w/osv_vuln.json
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def read(name):
    with open("/w/" + name, encoding="utf-8") as f:
        return f.read()


class Handler(BaseHTTPRequestHandler):
    def answer(self, body, status=200):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/feed.json":
            self.answer(read("osv_feed.json"))
        elif self.path.startswith("/v1/vulns/"):
            self.answer(read("osv_vuln.json"))
        else:
            self.answer("{}", 404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        wanted = read("osv_query_id.txt").strip()
        results = [{"vulns": [{"id": wanted, "modified": "2026-11-01T00:00:00Z"}]}
                   if q.get("package", {}).get("name") == "cowboy" else {} for q in body.get("queries", [])]
        self.answer(json.dumps({"results": results}))

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1])), Handler).serve_forever()
