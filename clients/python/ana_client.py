# SPDX-FileCopyrightText: 2026 LE Devices
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Python client for ANA ERP exposed programs (spec 003, RF-003-07).

Standard library only. Example:

    from ana_client import Ana
    ana = Ana("http://localhost:8080").login("admin", "admin")
    order = ana.call("sales.create_order", customer=1,
                     items=[{"product": "CAFE-500", "quantity": 2}])
    ana.call("sales.invoice_order", number=order["number"])
"""

import itertools
import json
import ssl
import urllib.error
import urllib.request

__all__ = ["Ana", "AnaRemoteError", "AnaHttpError"]


class AnaRemoteError(Exception):
    """Error returned by the exposed program (JSON-RPC error)."""

    def __init__(self, rpc_code, message, data=None):
        self.rpc_code = rpc_code
        self.message = message
        self.data = data or {}
        self.code = self.data.get("code")
        super().__init__(f"{self.code or rpc_code}: {message}")


class AnaHttpError(Exception):
    def __init__(self, status, body):
        self.status = status
        self.body = body
        super().__init__(f"HTTP {status}: {body}")


class Ana:
    def __init__(self, url, token=None, timeout=60, ssl_context=None):
        self.url = url.rstrip("/")
        self.token = token
        self.timeout = timeout
        self._ssl = ssl_context or ssl.create_default_context()
        self._ids = itertools.count(1)

    def _request(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.url + path, data=data, method=method,
                                     headers={"Content-Type": "application/json",
                                              "Accept": "application/json"})
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)
        kw = {"timeout": self.timeout}
        if req.full_url.startswith("https"):
            kw["context"] = self._ssl
        try:
            with urllib.request.urlopen(req, **kw) as r:
                text = r.read().decode()
                return json.loads(text) if text else None
        except urllib.error.HTTPError as e:
            raise AnaHttpError(e.code, e.read().decode(errors="replace")) from None

    def login(self, username, password):
        self.token = self._request("POST", "/api/session",
                                   {"username": username, "password": password})["token"]
        return self

    def call(self, function, **params):
        resp = self._request("POST", "/rpc", {"jsonrpc": "2.0", "method": function,
                                              "params": params, "id": next(self._ids)})
        return self._result(resp)

    def batch(self, calls):
        """calls: list of (function, params). Run in parallel on the server.
        Returns results or AnaRemoteError instances, in order."""
        requests = [{"jsonrpc": "2.0", "method": f, "params": p, "id": i}
                    for i, (f, p) in enumerate(calls)]
        replies = {r.get("id"): r for r in self._request("POST", "/rpc", requests)}
        out = []
        for i in range(len(calls)):
            try:
                out.append(self._result(replies[i]))
            except AnaRemoteError as e:
                out.append(e)
        return out

    def functions(self):
        return self._request("GET", "/rpc/functions")

    @staticmethod
    def _result(resp):
        if "error" in resp:
            e = resp["error"]
            raise AnaRemoteError(e.get("code"), e.get("message"), e.get("data"))
        return resp.get("result")
