"""ANA program runtime (specs 002 and 004).

Isolated process started by the Erlang core as a {packet, 4} port. It speaks
only the protocol described in specs/002-python-runtime/plan.md: JSON frames
with a 4-byte big-endian length prefix on stdin/stdout. It holds no database
credentials: every data access is requested from the core.

Each process serves a single execution (or inspection) and exits.
"""

import base64
import bdb
import builtins
import datetime
import decimal
import importlib.abc
import importlib.machinery
import io
import json
import linecache
import os
import re
import signal
import struct
import sys
import time
import traceback
import types

REPR_MAX = 200          # RF-004-02
MAX_VARIABLES = 100     # RF-004-02
FILE_PREFIX = "<ana:"


# ---------------------------------------------------------------------------
# Isolation (RNF-002-01)
# ---------------------------------------------------------------------------

def apply_limits(memory_mb, cpu_s):
    try:
        import resource
    except ImportError:  # pragma: no cover - platforms without resource
        return
    limits = [
        (getattr(resource, "RLIMIT_AS", None), memory_mb * 1024 * 1024),
        (getattr(resource, "RLIMIT_CPU", None), cpu_s),
        (getattr(resource, "RLIMIT_NOFILE", None), 64),
        (getattr(resource, "RLIMIT_FSIZE", None), 16 * 1024 * 1024),
        (getattr(resource, "RLIMIT_CORE", None), 0),
    ]
    for res, value in limits:
        if res is None or value < 0:
            continue
        try:
            _, hard = resource.getrlimit(res)
            if hard != resource.RLIM_INFINITY:
                value = min(value, hard)
            resource.setrlimit(res, (value, hard))
        except (ValueError, OSError):
            pass
    # Forbid fork/exec from programs (does not apply to root).
    nproc = getattr(resource, "RLIMIT_NPROC", None)
    if nproc is not None and os.getuid() != 0:
        try:
            resource.setrlimit(nproc, (0, resource.getrlimit(nproc)[1]))
        except (ValueError, OSError):
            pass


class CpuLimitExceeded(BaseException):
    """Raised when the execution exhausts its CPU budget (RF-012-06).

    BaseException on purpose: user code catching `Exception` cannot swallow it.
    """


def _cpu_seconds():
    import resource
    u = resource.getrusage(resource.RUSAGE_SELF)
    return u.ru_utime + u.ru_stime


def _on_cpu_limit(signum, frame):
    raise CpuLimitExceeded()


def apply_execution_limits(limits):
    """Per-execution limits (spec 012, RNF-012-01), applied by the OS.

    CPU: precise budget with ITIMER_PROF (process CPU time) plus RLIMIT_CPU as
    a hard backstop. Memory: RLIMIT_AS. Returns the CPU baseline for usage.
    """
    baseline = _cpu_seconds()
    try:
        import resource
    except ImportError:  # pragma: no cover
        return baseline
    cpu_ms = limits.get("cpu_ms")
    if cpu_ms:
        signal.signal(signal.SIGPROF, _on_cpu_limit)
        signal.signal(signal.SIGXCPU, _on_cpu_limit)
        signal.setitimer(signal.ITIMER_PROF, cpu_ms / 1000.0)
        try:
            _, hard = resource.getrlimit(resource.RLIMIT_CPU)
            soft = int(baseline + cpu_ms / 1000.0) + 2
            if hard != resource.RLIM_INFINITY:
                soft = min(soft, hard)
            resource.setrlimit(resource.RLIMIT_CPU, (soft, hard))
        except (ValueError, OSError):
            pass
    memory_mb = limits.get("memory_mb")
    if memory_mb:
        try:
            _, hard = resource.getrlimit(resource.RLIMIT_AS)
            value = memory_mb * 1024 * 1024
            if hard != resource.RLIM_INFINITY:
                value = min(value, hard)
            resource.setrlimit(resource.RLIMIT_AS, (value, hard))
        except (ValueError, OSError):
            pass
    return baseline


def usage(baseline):
    try:
        import resource
        u = resource.getrusage(resource.RUSAGE_SELF)
        return {"cpu_ms": int((u.ru_utime + u.ru_stime - baseline) * 1000), "max_rss_kb": int(u.ru_maxrss)}
    except Exception:  # noqa: BLE001
        return {"cpu_ms": 0, "max_rss_kb": 0}


# ---------------------------------------------------------------------------
# Protocol
# ---------------------------------------------------------------------------

class ChannelClosed(Exception):
    pass


def _json_default(obj):
    if isinstance(obj, decimal.Decimal):
        # Always text: exact precision and a stable type for JSON consumers;
        # the core converts it back to numeric.
        return str(obj)
    if isinstance(obj, (datetime.datetime, datetime.date, datetime.time)):
        return obj.isoformat()
    if isinstance(obj, (set, frozenset, tuple)):
        return list(obj)
    if isinstance(obj, bytes):
        return obj.decode("utf-8", "replace")
    raise TypeError(f"type {type(obj).__name__} is not JSON serializable")


def to_json(obj):
    return json.dumps(obj, default=_json_default, ensure_ascii=False, separators=(",", ":"))


class Channel:
    def __init__(self, stream_in, stream_out):
        self._in = stream_in
        self._out = stream_out
        self._seq = 0
        self.usage_baseline = None
        self.sql_seconds = 0.0          # time waiting for SQL answers (profile, spec 019)

    def send(self, msg):
        if msg.get("type") == "end" and self.usage_baseline is not None:
            signal.setitimer(signal.ITIMER_PROF, 0)
            msg = dict(msg, usage=usage(self.usage_baseline))
        data = to_json(msg).encode("utf-8")
        self._out.write(struct.pack(">I", len(data)) + data)
        self._out.flush()

    def _read(self, n):
        parts = []
        while n:
            chunk = self._in.read(n)
            if not chunk:
                raise ChannelClosed()
            parts.append(chunk)
            n -= len(chunk)
        return b"".join(parts)

    def receive(self):
        (size,) = struct.unpack(">I", self._read(4))
        return json.loads(self._read(size).decode("utf-8"))

    def request(self, op, args):
        """Synchronous request to the core; returns the value or raises Error."""
        self._seq += 1
        my_id = self._seq
        t0 = time.perf_counter() if op in ("sql", "sql_batch") else None
        try:
            return self._request(my_id, op, args)
        finally:
            if t0 is not None:
                self.sql_seconds += time.perf_counter() - t0

    def _request(self, my_id, op, args):
        self.send({"type": "request", "id": my_id, "op": op, "args": args})
        while True:
            msg = self.receive()
            kind = msg.get("type")
            if kind == "response" and msg.get("id") == my_id:
                if msg.get("ok"):
                    return msg.get("value")
                raise error_from_map(msg.get("error") or {})
            if kind == "cancel":
                raise SystemExit(1)
            # Any other message at this point is discarded.


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

class Error(Exception):
    """Business error: rolls back the execution transaction (RF-002-05)."""

    def __init__(self, code, message="", data=None):
        super().__init__(f"{code}: {message}" if message else code)
        self.code = str(code)
        self.message = str(message)
        self.data = data

    def as_map(self):
        m = {"code": self.code, "message": self.message}
        if self.data is not None:
            m["data"] = self.data
        return m


# Business rules enforced by the database raise "CODE: message" (check_violation or
# raise_exception): the code reaches the caller like any business error.
_DB_RULE = re.compile(r"([A-Z][A-Z0-9_]{2,40}): (.+)", re.S)


class SqlError(Error):
    def __init__(self, message, sqlstate=None, detail=None):
        if sqlstate == "25006":
            # Spec 009 (RF-009-05): the license is in restricted mode, executions are read-only.
            super().__init__("LICENSE_RESTRICTED", "licença vencida ou inválida: o ERP está somente para consulta "
                             "(peça ao administrador para instalar a licença)", {"sqlstate": sqlstate})
            self.sqlstate = sqlstate
            return
        if sqlstate == "42501" and "row-level security" in (message or ""):
            # Spec 009 (D10): the document falls outside the user's data scope.
            super().__init__("DATA_SCOPE", "o registro fica fora dos dados que você pode ver (centro de custo, carteira ou projetos)",
                             {"sqlstate": sqlstate})
            self.sqlstate = sqlstate
            return
        rule = _DB_RULE.fullmatch(message or "") if sqlstate in ("23514", "P0001") else None
        if rule:
            super().__init__(rule.group(1), rule.group(2), {"sqlstate": sqlstate, "detail": detail})
        else:
            super().__init__("SQL", message, {"sqlstate": sqlstate, "detail": detail})
        self.sqlstate = sqlstate


class ParamError(Error):
    def __init__(self, message):
        super().__init__("INVALID_PARAMETER", message)


def error_from_map(m):
    code = m.get("code", "ERROR")
    if code == "SQL":
        return SqlError(m.get("message", ""), m.get("sqlstate"), m.get("detail"))
    return Error(code, m.get("message", ""), m.get("data"))


# ---------------------------------------------------------------------------
# SQL result conversion
# ---------------------------------------------------------------------------

def _to_date(v):
    return datetime.date.fromisoformat(v)


def _to_timestamp(v):
    if v.endswith("Z"):
        v = v[:-1] + "+00:00"
    return datetime.datetime.fromisoformat(v)


def _to_time(v):
    return datetime.time.fromisoformat(v)


CONVERTERS = {
    "numeric": decimal.Decimal,
    "date": _to_date,
    "timestamp": _to_timestamp,
    "timestamptz": _to_timestamp,
    "time": _to_time,
}


def build_rows(result):
    """Turn compact {columns, rows} into a list of typed dicts."""
    columns = result.get("columns") or []
    names = [c["name"] for c in columns]
    conv = [CONVERTERS.get(c.get("type")) for c in columns]
    out = []
    for row in result.get("rows") or []:
        rec = {}
        for name, f, v in zip(names, conv, row):
            rec[name] = f(v) if (f is not None and v is not None) else v
        out.append(rec)
    return out


# ---------------------------------------------------------------------------
# Output (RF-002-06, RNF-002-06)
# ---------------------------------------------------------------------------

class Output(io.TextIOBase):
    def __init__(self, channel, limit):
        self._channel = channel
        self._buf = []
        self._buf_size = 0
        self._remaining = limit
        self._truncated = False

    def writable(self):
        return True

    def write(self, text):
        if not isinstance(text, str):
            text = str(text)
        self._buf.append(text)
        self._buf_size += len(text)
        if "\n" in text or self._buf_size > 8192:
            self.flush()
        return len(text)

    def flush(self):
        if not self._buf:
            return
        text = "".join(self._buf)
        self._buf, self._buf_size = [], 0
        self.emit("text", text)

    def emit(self, kind, data):
        if self._truncated:
            return
        size = len(data) if isinstance(data, str) else len(to_json(data))
        if size > self._remaining:
            self._truncated = True
            self._channel.send({"type": "output", "kind": "log",
                                "data": {"level": "warning",
                                         "message": "saída truncada: limite atingido"}})
            return
        self._remaining -= size
        self._channel.send({"type": "output", "kind": kind, "data": data})


# ---------------------------------------------------------------------------
# The `ana` module (RF-002-05)
# ---------------------------------------------------------------------------

class Context:
    def __init__(self, d):
        self.user = d.get("user")
        self.role = d.get("role")
        self.party = d.get("party")          # external portal accounts (spec 016)
        self.public_url = d.get("public_url") or ""   # e.g. https://erp.empresa.com.br (spec 037)
        self.execution_id = d.get("execution_id")
        self.program = d.get("program")
        self.version = d.get("version")
        self.origin = d.get("origin")
        self.depth = d.get("depth", 0)

    def __repr__(self):
        return (f"Context(user={self.user!r}, program={self.program!r}, "
                f"version={self.version!r}, origin={self.origin!r})")


class Part:
    """Handle of a parallel part (spec 022)."""
    __slots__ = ("handle", "program")

    def __init__(self, handle, program):
        self.handle = handle
        self.program = program

    def __repr__(self):
        return f"Part({self.handle}, {self.program!r})"


class _Savepoint:
    def __init__(self, channel):
        self._channel = channel

    def __enter__(self):
        self._name = self._channel.request("savepoint", {"action": "create"})
        return self

    def __exit__(self, exc_type, exc, tb):
        action = "release" if exc_type is None else "rollback"
        self._channel.request("savepoint", {"action": action, "name": self._name})
        return False


_NEXT_FIELD = re.compile(r"\{\{(result|params)\.([A-Za-z_][A-Za-z0-9_]*)\}\}")


def _next_actions(spec, result, params, output):
    """RF-020-10: `NEXT = [{"program", "label", "params": {"field": "{{result.x}}" | "{{params.y}}" | value},
    "when"?: "result.x", "style"?, "confirm"?, "open"?}]` becomes the "Próximo passo" buttons with the context
    filled in. An action whose value is missing (or whose `when` is false) is left out."""
    if not spec or not isinstance(spec, (list, tuple)):
        return
    sources = {"result": result if isinstance(result, dict) else {}, "params": params or {}}

    def value(v):
        if isinstance(v, str):
            whole = _NEXT_FIELD.fullmatch(v)
            if whole:
                return sources[whole.group(1)].get(whole.group(2))
            return _NEXT_FIELD.sub(lambda m: str(sources[m.group(1)].get(m.group(2), "")), v)
        return v

    items = []
    for a in spec:
        if not isinstance(a, dict) or not a.get("program") or not a.get("label"):
            continue
        when = a.get("when")
        if when and not value("{{" + when + "}}"):
            continue
        filled = {k: value(v) for k, v in (a.get("params") or {}).items()}
        if any(v is None or v == "" for v in filled.values()):
            continue
        items.append({**{k: a[k] for k in ("style", "open") if k in a},
                      **({"confirm": str(value(a["confirm"]))} if a.get("confirm") else {}),
                      "label": str(value(a["label"])), "program": a["program"], "params": filled})
    if items:
        output.flush()
        output.emit("actions", {"title": "Próximo passo", "items": items})


def make_ana_module(channel, output, context):
    m = types.ModuleType("ana", "ANA ERP API for programs.")

    def where():
        """Program and line that issued the SQL (spec 019: SQL measured per call site)."""
        f = sys._getframe(2)
        while f is not None:
            name = f.f_code.co_filename
            if name.startswith(FILE_PREFIX):
                return [name[len(FILE_PREFIX):-1], f.f_lineno]
            f = f.f_back
        return None

    def sql(query, *params):
        """Run SQL and return a list of dicts. Parameters: $1, $2, ..."""
        return build_rows(channel.request("sql", {"sql": query, "params": list(params), "at": where()}))

    def sql_one(query, *params):
        rows = sql(query, *params)
        return rows[0] if rows else None

    def sql_value(query, *params):
        rows = sql(query, *params)
        if not rows:
            return None
        return next(iter(rows[0].values()), None)

    def sql_exec(query, *params):
        return channel.request("sql", {"sql": query, "params": list(params), "at": where()}).get("affected", 0)

    def sql_batch(query, rows):
        """Run the same statement for each parameter list (P12)."""
        batch = [list(p) for p in rows]
        if not batch:
            return 0
        return channel.request("sql_batch", {"sql": query, "batch": batch, "at": where()}).get("affected", 0)

    def call(program, **params):
        """Run another program in the same execution transaction (RF-002-08)."""
        return channel.request("call", {"program": program, "params": params})

    def schedule_job(name, program, params=None, cron=None, active=True, description=""):
        """Keeps a scheduler job of the program's own module (spec 039, T-039-17b): name "bpm.x" from a bpm.* program.
        cron None or active False stops it. Validated by the scheduler as for the user running the program; done
        outside the program's transaction (call it last). Returns {"job": id | None}."""
        return channel.request("schedule", {"name": name, "program": program, "params": params or {}, "cron": cron,
                                             "active": bool(active), "description": description})

    def extend(point, data):
        """Extension point of a product program (spec 009, D9). Runs the customer programs registered for
        `point` (main(point, data)), in order, in the same transaction. A before_* program may refuse by
        raising ana.Error, or return a dict whose allowed fields adjust `data`; after_* only receives it.
        Returns the (possibly adjusted) data."""
        reg = channel.request("extensions", {"point": point}) or {}
        if not reg.get("programs"):
            return dict(data or {})
        data = json.loads(json.dumps(data or {}, default=str))      # dates and decimals travel as text
        for program in reg.get("programs") or []:
            r = channel.request("call", {"program": program, "params": {"point": point, "data": data}})
            if point.startswith("before_") and isinstance(r, dict):
                data.update({k: v for k, v in r.items() if k in (reg.get("adjust") or [])})
        return data

    def remote(system, function, **params):
        """Call an exposed program on a registered remote system (RF-003-08)."""
        return channel.request("remote", {"system": system, "function": function, "params": params})

    class HttpResponse(dict):
        """Answer of ana.http: status, headers, json (when JSON) or text; .ok for 2xx."""
        @property
        def ok(self):
            return 200 <= self.get("status", 0) < 300

    def http(connector, method, path="", json=None, body=None, headers=None, params=None):
        """HTTP call through a connector (spec 017): the core adds credentials, checks the
        allowed hosts and applies limits. Programs never see secrets nor open sockets."""
        options = {}
        if json is not None:
            options["json"] = json
        elif body is not None:
            options["body"] = str(body)
        if headers:
            options["headers"] = {str(k): str(v) for k, v in dict(headers).items()}
        if params:
            options["params"] = {str(k): v for k, v in dict(params).items()}
        r = channel.request("http", {"connector": str(connector), "method": str(method), "path": str(path),
                                     "options": options})
        return HttpResponse(r)

    def send(connector, kind, payload, key=None):
        """Queue a message for the connector in this same transaction (outbox, spec 017):
        delivered after the commit, with retries; nothing is sent if the execution fails."""
        return sql_value("SELECT integration.enqueue($1, $2, $3::text::jsonb, $4) AS id", str(connector), str(kind),
                         to_json(payload), key)

    class Files:
        """Repository (spec 016), with the permissions of the execution's user.
        Writes are immediate (like ana.remote), not part of the execution transaction."""

        @staticmethod
        def _where(folder=None, entity=None, subfolder=None):
            w = {}
            if entity is not None:
                kind, ident = entity
                w["entity"] = {"kind": str(kind), "id": int(ident)}
            elif folder is not None:
                w["folder"] = folder if isinstance(folder, int) else str(folder)
            if subfolder:
                w["subfolder"] = str(subfolder)
            return w

        def put(self, name, data, folder=None, entity=None, subfolder=None, comment=None):
            """Stores bytes (or text, as UTF-8) as a new file or a new version: {file, version, size, mime}."""
            raw = data.encode("utf-8") if isinstance(data, str) else bytes(data)
            return channel.request("files", {"action": "put", "name": str(name), "comment": comment,
                                             "data": base64.b64encode(raw).decode("ascii"),
                                             **self._where(folder, entity, subfolder)})

        def publish(self, kind, party, name, data, comment=None):
            """Spec 037: a document for a customer/supplier, in the partner's folder for that kind
            (Pedidos, Faturas, Entregas, Atendimentos, Recibos, Extratos, Ordens de compra), which only
            that partner's accounts reach. Internal kinds are refused (INTERNAL_DOCUMENT)."""
            raw = data.encode("utf-8") if isinstance(data, str) else bytes(data)
            return channel.request("files", {"action": "publish", "kind": str(kind), "party": int(party), "name": str(name),
                                             "comment": comment, "data": base64.b64encode(raw).decode("ascii")})

        def link(self, file, hours=72, max_downloads=None, password=None):
            """Spec 037: download link without an account ({id, token, url}); only for files in
            folders made for partners."""
            body = {"action": "link", "file": int(file), "hours": int(hours)}
            if max_downloads:
                body["max_downloads"] = int(max_downloads)
            if password:
                body["password"] = str(password)
            return channel.request("files", body)

        def get(self, file, version=None):
            """{name, mime, version, data: bytes}."""
            r = channel.request("files", {"action": "get", "file": int(file), "version": version})
            r["data"] = base64.b64decode(r["data"])
            return r

        def list(self, folder=None):
            return channel.request("files", {"action": "list", "folder": folder})

        def folder(self, folder=None, entity=None, subfolder=None, create=True):
            """Id of a folder by path ("/Clientes/ACME") or entity (("party", 7)), created if missing."""
            return channel.request("files", {"action": "folder", "create": bool(create),
                                             **self._where(folder, entity, subfolder)})

        def grant(self, subject_kind, subject, level, folder_id=None, file_id=None, expires_at=None, deny=False):
            body = {"action": "grant", "subject_kind": subject_kind, "subject": str(subject), "level": level,
                    "deny": bool(deny), "expires_at": expires_at}
            if folder_id is not None:
                body["folder_id"] = int(folder_id)
            if file_id is not None:
                body["file_id"] = int(file_id)
            return channel.request("files", body)

    def log(message, level="info"):
        output.flush()
        output.emit("log", {"level": str(level), "message": str(message)})

    def table(rows, title=None):
        """Rows are dicts; the optional key `_actions` holds per-row actions and `_open` the
        document the row opens when clicked (spec 035: {"program", "params"})."""
        output.flush()
        rows = list(rows)
        columns = []
        for rec in rows:
            for k in rec.keys():
                if k not in columns and k not in ("_actions", "_open"):
                    columns.append(k)
        data = {
            "title": title,
            "columns": columns,
            "rows": [[rec.get(c) for c in columns] for rec in rows],
        }
        if any(rec.get("_actions") for rec in rows):
            data["row_actions"] = [_actions(rec.get("_actions") or []) for rec in rows]
        if any(rec.get("_open") for rec in rows):
            data["row_open"] = [_actions([{"label": "Abrir", **rec["_open"], "open": True}])[0] if rec.get("_open") else None
                                for rec in rows]
        output.emit("table", data)

    # Rich views (spec 021): rendered by the UI for any program.
    def _actions(items):
        out = []
        for a in items:
            if not isinstance(a, dict) or not a.get("label") or not a.get("program"):
                raise ParamError("ação exige label e program")
            out.append({k: a[k] for k in ("label", "program", "params", "ask", "open", "style", "confirm", "download")
                        if k in a})
        return out

    def metrics(items, title=None):
        """KPI cards: [{"label", "value", "hint"?, "status"?: ok|warn|bad}]."""
        output.flush()
        output.emit("metrics", {"title": title, "items": list(items)})

    def grid(rows, dimensions, periods, title=None, value_label="Planejado", consumed_label=None, available_label=None,
             save=None, version=None, negative=False, decimals=2, statuses=None, comments=False, add=None, unit=None):
        """Planning grid by period (spec 020, RF-020-15/16). dimensions: [{"key", "label"}] fixed on the left;
        periods: [{"key", "label"}]; rows: [{"key": {dim: value}, "labels"?: {dim: text}, "values": {period: n},
        "consumed"?: {period: n}, "status"?, "comment"?}]. save: {"program", "params"?} receives
        {"changes": [{"key", "values"?: {period: n|None}, "status"?, "comment"?}], "version"} and saves only
        what changed; version: token of what was read (concurrent editing). add: {dim: lookup} to include rows."""
        output.flush()
        dims = [{"key": str(d["key"]), "label": str(d.get("label") or d["key"])} for d in dimensions]
        pers = [{"key": str(p["key"]), "label": str(p.get("label") or p["key"])} for p in periods]
        if not dims or not pers:
            raise ParamError("grid exige dimensões e períodos")
        if save is not None and (not isinstance(save, dict) or not save.get("program")):
            raise ParamError("save da grade exige program")
        num = lambda v: None if v is None else str(v) if isinstance(v, decimal.Decimal) else v
        out = []
        for r in rows:
            key = {d["key"]: r["key"].get(d["key"]) for d in dims}
            out.append({"key": key, "labels": {k: str(v) for k, v in (r.get("labels") or {}).items()},
                        "values": {str(k): num(v) for k, v in (r.get("values") or {}).items()},
                        **({"consumed": {str(k): num(v) for k, v in r["consumed"].items()}} if r.get("consumed") is not None else {}),
                        **({"status": r.get("status")} if statuses else {}),
                        **({"comment": r.get("comment") or ""} if comments else {})})
        output.emit("grid", {"title": title, "dimensions": dims, "periods": pers, "rows": out, "value_label": value_label,
                             "consumed_label": consumed_label, "available_label": available_label, "save": save,
                             "version": version, "negative": bool(negative), "decimals": int(decimals), "unit": unit,
                             "statuses": statuses, "comments": bool(comments), "add": add})

    def steps(items, title=None):
        """Stages of a process (RF-020-11): [{"label", "status": done|current|todo, "hint"?}]."""
        output.flush()
        output.emit("steps", {"title": title, "items": [{k: i.get(k) for k in ("label", "status", "hint")} for i in items]})

    def board(columns, cards, title=None):
        """Kanban: columns [{"key", "label"}]; cards [{"column", "title", "subtitle"?,
        "badges"?, "actions"?}]."""
        output.flush()
        output.emit("board", {"title": title, "columns": list(columns),
                              "cards": [{**c, "actions": _actions(c.get("actions") or [])} for c in cards]})

    def gantt(items, title=None, today=None):
        """Timeline: [{"code", "name", "start", "finish", "level"?, "critical"?, "progress"?,
        "baseline_start"?, "baseline_finish"?, "kind"?}]."""
        output.flush()
        output.emit("gantt", {"title": title, "today": today, "items": list(items)})

    CHART_TYPES = ("line", "area", "column", "stacked", "bar", "donut")
    CHART_FORMATS = ("number", "money", "percent", "hours")

    def chart(spec=None, **kw):
        """Chart (spec 026): {"type", "title"?, "subtitle"?, "x": [...], "series": [{"name", "values"}],
        "format"?: number|money|percent|hours, "unit"?}. More than 8 series fold into "Outros";
        a donut keeps at most 6 slices (the rest is "Outros")."""
        spec = {**(spec or {}), **kw}
        kind = spec.get("type", "line")
        if kind not in CHART_TYPES:
            raise ParamError(f"tipo de gráfico desconhecido: {kind} (use {', '.join(CHART_TYPES)})")
        fmt = spec.get("format", "number")
        if fmt not in CHART_FORMATS:
            raise ParamError(f"formato desconhecido: {fmt}")
        x = list(spec.get("x") or [])
        series = []
        for s in spec.get("series") or []:
            if not isinstance(s, dict) or "values" not in s:
                raise ParamError("cada série precisa de name e values")
            vals = []
            for v in s["values"]:
                if v is None:
                    vals.append(None)
                    continue
                try:
                    vals.append(float(v))
                except (TypeError, ValueError):
                    raise ParamError(f"valor não numérico na série {s.get('name')!r}: {v!r}") from None
            if len(vals) != len(x):
                raise ParamError(f"a série {s.get('name')!r} tem {len(vals)} valores e o eixo x tem {len(x)}")
            series.append({"name": str(s.get("name", f"série {len(series) + 1}")), "values": vals})
        if not series:
            raise ParamError("o gráfico precisa de pelo menos uma série")
        if kind == "donut":
            if len(series) != 1:
                raise ParamError("a rosca usa uma série (as fatias são o eixo x)")
            pairs = sorted(zip(x, series[0]["values"]), key=lambda p: -(p[1] or 0))
            if len(pairs) > 6:
                rest = sum(v or 0 for _, v in pairs[5:])
                pairs = pairs[:5] + [("Outros", rest)]
            x = [p[0] for p in pairs]
            series = [{"name": series[0]["name"], "values": [p[1] for p in pairs]}]
        elif len(series) > 8:
            # Never a 9th color: the smallest series fold into "Outros" (by total).
            ranked = sorted(series, key=lambda s: -sum(abs(v or 0) for v in s["values"]))
            keep, rest = ranked[:7], ranked[7:]
            other = [sum((s["values"][i] or 0) for s in rest) for i in range(len(x))]
            order = {id(s): i for i, s in enumerate(series)}
            series = sorted(keep, key=lambda s: order[id(s)]) + [{"name": "Outros", "values": other}]
        output.flush()
        output.emit("chart", {"type": kind, "title": spec.get("title"), "subtitle": spec.get("subtitle"),
                              "x": [x_.isoformat() if hasattr(x_, "isoformat") else x_ for x_ in x],
                              "series": series, "format": fmt, "unit": spec.get("unit")})

    def tabs(items, current=None):
        """Tab bar; each item is an action with `open`: the routine reruns in place."""
        output.flush()
        output.emit("tabs", {"current": current, "items": _actions(items)})

    def actions(items, title=None):
        """Buttons: next steps (RF-020-10) or operations with an inline form (`ask`)."""
        output.flush()
        output.emit("actions", {"title": title, "items": _actions(items)})

    def savepoint():
        """`with ana.savepoint():` — a failure inside rolls back only the block."""
        return _Savepoint(channel)

    # Parallel parts (spec 022). Each part is an execution of its own (process,
    # transaction, limits, audit) with the same user; results come back in order.
    groups = iter(range(1, 1 << 30))

    def _spawn(program, params, group, max_workers, mode, snapshot, timeout_ms):
        if mode not in ("independent", "atomic"):
            raise ParamError("mode deve ser 'independent' ou 'atomic'")
        if params is not None and not isinstance(params, dict):
            raise ParamError("params de cada parte deve ser um dicionário")
        h = channel.request("spawn", {"program": str(program), "params": params or {}, "group": group,
                                      "max_workers": max_workers, "mode": mode, "snapshot": bool(snapshot),
                                      "timeout_ms": timeout_ms})
        return Part(h, program)

    def spawn(program, params=None, *, mode="independent", snapshot=False, timeout_ms=None):
        """Starts one part now and returns a `Part`; collect it later with `ana.gather`."""
        return _spawn(program, params, next(groups), 1, mode, snapshot, timeout_ms)

    def gather(*parts, fail_fast=False, timeout_ms=None):
        """Waits for the parts; returns [{"ok": True, "result": …} | {"ok": False, "error": {…}}] in order."""
        if len(parts) == 1 and isinstance(parts[0], (list, tuple)):
            parts = tuple(parts[0])
        if not all(isinstance(x, Part) for x in parts):
            raise ParamError("gather recebe partes criadas por ana.spawn")
        if not parts:
            return []
        return channel.request("gather", {"handles": [x.handle for x in parts], "fail_fast": bool(fail_fast),
                                          "timeout_ms": timeout_ms})

    def parallel(calls, max_workers=None, mode="independent", snapshot=False, timeout_ms=None, fail_fast=False):
        """Runs [(program, params), ...] in parallel (at most `max_workers` at a time) and joins them."""
        group = next(groups)
        parts = [_spawn(c[0], c[1] if len(c) > 1 else None, group, max_workers, mode, snapshot, timeout_ms)
                 for c in calls]
        return gather(*parts, fail_fast=fail_fast)

    def map_(program, params_list, max_workers=None, mode="independent", snapshot=False, timeout_ms=None,
             fail_fast=False):
        """Applies one program to each params dict, in parallel; results in input order."""
        return parallel([(program, p) for p in params_list], max_workers=max_workers, mode=mode,
                        snapshot=snapshot, timeout_ms=timeout_ms, fail_fast=fail_fast)

    def cancel(*parts):
        channel.request("cancel", {"handles": [x.handle for x in parts]})

    m.sql = sql
    m.sql_one = sql_one
    m.sql_value = sql_value
    m.sql_exec = sql_exec
    m.sql_batch = sql_batch
    m.call = call
    m.steps = steps
    m.grid = grid
    m.extend = extend
    m.schedule_job = schedule_job
    m.remote = remote
    m.http = http
    m.send = send
    m.files = Files()
    m.log = log
    m.table = table
    m.metrics = metrics
    m.chart = chart
    m.board = board
    m.gantt = gantt
    m.tabs = tabs
    m.actions = actions
    m.savepoint = savepoint
    m.spawn = spawn
    m.gather = gather
    m.parallel = parallel
    m.map = map_
    m.cancel = cancel
    m.Part = Part
    m.context = context
    m.Error = Error
    m.SqlError = SqlError
    m.ParamError = ParamError
    return m


# ---------------------------------------------------------------------------
# Library importer `ana_lib.*` (RF-002-07)
# ---------------------------------------------------------------------------

class LibraryImporter(importlib.abc.MetaPathFinder, importlib.abc.Loader):
    ROOT = "ana_lib"

    def __init__(self, channel, ana_mod):
        self._channel = channel
        self._ana = ana_mod
        self._sources = {}

    def find_spec(self, name, path=None, target=None):
        if name != self.ROOT and not name.startswith(self.ROOT + "."):
            return None
        if name == self.ROOT:
            return importlib.machinery.ModuleSpec(name, self, is_package=True)
        prog = name[len(self.ROOT) + 1:]
        r = self._channel.request("library_source", {"name": prog})
        if r.get("source") is not None:
            self._sources[name] = r
            return importlib.machinery.ModuleSpec(name, self, is_package=False,
                                                  origin=FILE_PREFIX + prog + ">")
        if r.get("package"):
            return importlib.machinery.ModuleSpec(name, self, is_package=True)
        return None

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        name = module.__name__
        if name not in self._sources:
            module.__path__ = []
            return
        info = self._sources.pop(name)
        prog = name[len(self.ROOT) + 1:]
        filename = FILE_PREFIX + prog + ">"
        register_source(filename, info["source"])
        module.__file__ = filename
        module.ana = self._ana
        exec(compile(info["source"], filename, "exec"), module.__dict__)


def register_source(filename, source):
    linecache.cache[filename] = (len(source), None, source.splitlines(True), filename)


# ---------------------------------------------------------------------------
# Parameters (RF-002-04)
# ---------------------------------------------------------------------------

def _to_int(v):
    if isinstance(v, bool):
        raise ValueError
    if isinstance(v, float) and not v.is_integer():
        raise ValueError
    return int(v)


def _to_bool(v):
    if isinstance(v, bool):
        return v
    if isinstance(v, str) and v.lower() in ("true", "yes", "1"):
        return True
    if isinstance(v, str) and v.lower() in ("false", "no", "0"):
        return False
    if v in (0, 1):
        return bool(v)
    raise ValueError


def _to_list(v):
    if not isinstance(v, list):
        raise ValueError
    return v


def _to_dict(v):
    if not isinstance(v, dict):
        raise ValueError
    return v


def _to_condition(v):
    """Restricted rule (spec 020, RF-020-14): a list of rules or {"any": [[rule]], "except": [rule]}; JSON text too."""
    if isinstance(v, str):
        v = json.loads(v) if v.strip() else []
    if not isinstance(v, (list, dict)):
        raise ValueError
    return v


def _to_str(v):
    if isinstance(v, (dict, list)):
        raise ValueError
    return str(v)


def _to_decimal(v):
    """Decimal from JSON numbers or typed text; Brazilian notation ("1.234,56", "4,79") accepted."""
    if isinstance(v, (int, float, decimal.Decimal)) and not isinstance(v, bool):
        return decimal.Decimal(str(v))
    s = str(v).strip()
    if "," in s:
        s = s.replace(".", "").replace(",", ".")
    return decimal.Decimal(s)


PARAM_TYPES = {
    "int": _to_int,
    "float": float,
    "decimal": _to_decimal,
    "str": _to_str,
    "bool": _to_bool,
    "date": lambda v: v if isinstance(v, datetime.date) else datetime.date.fromisoformat(v),
    # Spec 029: date and time pickers on screen send ISO text ("2026-10-05T14:30", "14:30").
    "datetime": lambda v: v if isinstance(v, datetime.datetime) else datetime.datetime.fromisoformat(str(v).replace(" ", "T")),
    "time": lambda v: v if isinstance(v, datetime.time) else datetime.time.fromisoformat(str(v)),
    "list": _to_list,
    "dict": _to_dict,
    "condition": _to_condition,
}


def _check_rows(name, spec, rows):
    """Rows of a list with declared columns (spec 042, B-02): each one an object with its required columns, each
    value of the column's type — the program never meets a malformed row (the values themselves are not changed)."""
    label = spec.get("label") or name
    single = next(iter(spec["columns"])) if len(spec["columns"]) == 1 else None
    for i, row in enumerate(rows, start=1):
        if not isinstance(row, dict):
            if single is None or isinstance(row, list):
                raise ParamError(f"{label}, linha {i}: deve ser um objeto com as colunas")
            row = {single: row}              # one column: a plain value stands for it (["AVISTA"] = [{"term": "AVISTA"}])
        for col, cs in spec["columns"].items():
            cs = cs or {}
            v = row.get(col)
            if v is None or v == "":
                if cs.get("required") and cs.get("default") is None:
                    known = ", ".join(spec["columns"])
                    raise ParamError(f"{label}, linha {i}: falta {cs.get('label') or col} (colunas: {known})")
                continue
            conv = PARAM_TYPES.get(cs.get("type", "str"))
            if conv is None:
                continue
            try:
                conv(v)
            except (ValueError, TypeError, decimal.InvalidOperation):
                raise ParamError(f"{label}, linha {i}: {cs.get('label') or col} não é do tipo {cs.get('type', 'str')}") from None


def validate_params(declaration, received):
    if declaration is None:
        return dict(received)
    if not isinstance(declaration, dict):
        raise ParamError("PARAMS deve ser um dicionário")
    unknown = set(received) - set(declaration)
    if unknown:
        raise ParamError("parâmetros desconhecidos: " + ", ".join(sorted(unknown)))
    out = {}
    for name, spec in declaration.items():
        spec = spec or {}
        kind = spec.get("type", "str")
        if name not in received or received[name] is None:
            if spec.get("required"):
                raise ParamError(f"parâmetro obrigatório ausente: {name}")
            if "default" in spec:
                out[name] = spec["default"]
            continue
        conv = PARAM_TYPES.get(kind)
        if conv is None:
            raise ParamError(f"tipo desconhecido para {name}: {kind}")
        try:
            out[name] = conv(received[name])
        except (ValueError, TypeError, decimal.InvalidOperation):
            raise ParamError(f"parâmetro {name} não é do tipo {kind}") from None
        if kind == "list" and isinstance(spec.get("columns"), dict):
            _check_rows(name, spec, out[name])
        choices = spec.get("choices")
        if choices:
            allowed = [c[0] if isinstance(c, (list, tuple)) else c for c in choices]
            if out[name] not in allowed:
                raise ParamError(f"parâmetro {name}: valor fora das opções ({', '.join(map(str, allowed))})")
    return out


# ---------------------------------------------------------------------------
# Debugger (spec 004)
# ---------------------------------------------------------------------------

def _short_repr(v):
    try:
        r = repr(v)
    except Exception as e:  # a user object's repr may fail
        r = f"<repr failed: {e!r}>"
    if len(r) > REPR_MAX:
        r = r[:REPR_MAX - 1] + "…"
    return r


def collect_variables(frame):
    variables = []
    for name, value in list(frame.f_locals.items()):
        if name.startswith("__") or isinstance(value, types.ModuleType):
            continue
        if frame.f_code.co_name == "<module>" and isinstance(value, (types.FunctionType, type)):
            continue
        variables.append({"name": name, "type": type(value).__name__, "value": _short_repr(value)})
        if len(variables) >= MAX_VARIABLES:
            break
    return variables


class AnaDebugger(bdb.Bdb):
    def __init__(self, channel, filename, breakpoints):
        super().__init__()
        self.channel = channel
        self.filename = filename
        self.set_breakpoints(breakpoints)

    def set_breakpoints(self, lines):
        self.clear_all_file_breaks(self.filename)
        accepted = []
        for line in lines or []:
            try:
                line = int(line)
            except (TypeError, ValueError):
                continue
            if self.set_break(self.filename, line) is None:
                accepted.append(line)
        return accepted

    def run_debugged(self, func, stop_on_entry=False):
        """Run `func` under the debugger.

        Without `stop_on_entry` it starts in "continue" mode: only breakpoints
        stop, and frames without breakpoints are not traced (RNF-004-05).
        """
        self.reset()
        if not stop_on_entry:
            self._set_stopinfo(sys._getframe(), None, -1)
        self.quitting = False
        sys.settrace(self.trace_dispatch)
        try:
            return func()
        finally:
            self.quitting = True
            sys.settrace(None)

    def _stack(self, frame):
        stack = []
        f = frame
        while f is not None:
            if f.f_code.co_filename == self.filename:
                stack.append({"function": f.f_code.co_name, "line": f.f_lineno})
            f = f.f_back
        return stack

    def user_call(self, frame, argument_list):
        pass

    def user_return(self, frame, return_value):
        pass

    def user_exception(self, frame, exc_info):
        pass

    def user_line(self, frame):
        # RF-004-07: stop only on lines of the debugged program.
        if frame.f_code.co_filename != self.filename:
            return
        reason = "breakpoint" if self.break_here(frame) else "step"
        sys.stdout.flush()
        self.channel.send({
            "type": "pause",
            "reason": reason,
            "line": frame.f_lineno,
            "function": frame.f_code.co_name,
            "stack": self._stack(frame),
            "variables": collect_variables(frame),
        })
        self.wait_command(frame)

    def wait_command(self, frame):
        while True:
            msg = self.channel.receive()
            if msg.get("type") == "cancel":
                raise SystemExit(1)
            if msg.get("type") != "debug":
                continue
            action = msg.get("action")
            if action == "continue":
                self.set_continue()
                return
            if action == "over":
                self.set_next(frame)
                return
            if action == "into":
                self.set_step()
                return
            if action == "out":
                self.set_return(frame)
                return
            if action == "stop":
                self.set_quit()
                return
            if action == "eval":
                self.channel.send(self.evaluate(frame, msg.get("expression", "")))
            elif action == "breakpoints":
                accepted = self.set_breakpoints(msg.get("lines"))
                self.channel.send({"type": "breakpoints", "lines": accepted})

    def evaluate(self, frame, expression):
        resp = {"type": "eval", "expression": expression}
        try:
            try:
                code = compile(expression, "<eval>", "eval")
                is_eval = True
            except SyntaxError:
                code = compile(expression, "<eval>", "exec")
                is_eval = False
            # Tracing is suspended while evaluating.
            trace = sys.gettrace()
            sys.settrace(None)
            try:
                if is_eval:
                    value = eval(code, frame.f_globals, frame.f_locals)
                else:
                    exec(code, frame.f_globals, frame.f_locals)
                    value = None
            finally:
                sys.settrace(trace)
            resp.update(ok=True, value=_short_repr(value))
        except Exception as e:
            resp.update(ok=False, value=f"{type(e).__name__}: {e}")
        resp["variables"] = collect_variables(frame)
        return resp


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

def _program_trace(exc):
    """Traceback with ANA program frames only (hides the runtime)."""
    tb = traceback.extract_tb(exc.__traceback__)
    frames = [f for f in tb if f.filename.startswith(FILE_PREFIX)]
    lines = [f'  {f.filename} line {f.lineno}, in {f.name}\n    {f.line or ""}' for f in frames]
    lines.append(f"{type(exc).__name__}: {exc}")
    return "\n".join(lines)


SENSITIVE = re.compile(r"pass(word|wd)?|senha|secret|token|key|cpf|cnpj|card|cartao", re.I)


def _error_frames(exc):
    """RF-019-04: program/library frames (where, line, function, code) and the locals of
    the frame where the error happened — sensitive names masked, reprs truncated."""
    frames, last = [], None
    tb = exc.__traceback__
    while tb is not None:
        f = tb.tb_frame
        name = f.f_code.co_filename
        if name.startswith(FILE_PREFIX):
            frames.append({"where": name[len(FILE_PREFIX):-1], "line": tb.tb_lineno, "function": f.f_code.co_name,
                           "code": (linecache.getline(name, tb.tb_lineno) or "").strip()})
            last = f
        tb = tb.tb_next
    local_vars = {}
    if last is not None:
        for k, v in list(last.f_locals.items())[:MAX_VARIABLES]:
            if k.startswith("__") or isinstance(v, types.ModuleType) or callable(v) and not isinstance(v, (int, float, str)):
                continue
            local_vars[k] = "***" if SENSITIVE.search(k) else _short_repr(v)
    return frames, local_vars


def _error_line(exc, filename):
    tb = traceback.extract_tb(exc.__traceback__)
    for f in reversed(tb):
        if f.filename == filename:
            return f.lineno
    if isinstance(exc, SyntaxError) and exc.filename == filename:
        return exc.lineno
    return None


def run(channel, msg, output_limit):
    program = msg["program"]
    source = msg["source"]
    filename = FILE_PREFIX + program + ">"
    ctx = dict(msg.get("context") or {})
    ctx.setdefault("program", program)
    ctx.setdefault("version", msg.get("version"))
    context = Context(ctx)

    limits = msg.get("limits") or {}
    if limits.get("output_kb"):
        output_limit = int(limits["output_kb"]) * 1024
    output = Output(channel, output_limit)
    sys.stdout = output
    ana_mod = make_ana_module(channel, output, context)
    sys.modules["ana"] = ana_mod
    sys.meta_path.insert(0, LibraryImporter(channel, ana_mod))
    register_source(filename, source)

    debugger = None
    if msg.get("debug"):
        debugger = AnaDebugger(channel, filename, msg.get("breakpoints") or [])

    profiler = None
    module_globals = {"__name__": "__ana__", "__file__": filename,
                      "__builtins__": builtins, "ana": ana_mod}
    channel.usage_baseline = apply_execution_limits(limits)
    try:
        code = compile(source, filename, "exec")
        if debugger:
            debugger.run_debugged(lambda: exec(code, module_globals))
        else:
            exec(code, module_globals)
        main = module_globals.get("main")
        if not callable(main):
            raise Error("NO_MAIN", "o programa não define main(**params)")
        params = validate_params(module_globals.get("PARAMS"), msg.get("params") or {})
        if debugger:
            result = debugger.run_debugged(lambda: main(**params), bool(msg.get("stop_on_entry")))
        else:
            if msg.get("profile"):
                import cProfile
                profiler = cProfile.Profile()
                profiler.enable()
            try:
                result = main(**params)
            finally:
                if profiler:
                    profiler.disable()
        if (msg.get("context") or {}).get("depth", 0) == 0:
            _next_actions(module_globals.get("NEXT"), result, params, output)
        output.flush()
        try:
            to_json(result)
        except (TypeError, ValueError) as e:
            raise Error("INVALID_RESULT", str(e)) from None
        channel.send({"type": "end", "ok": True, "result": result, "profile": profile_of(profiler, channel)})
    except CpuLimitExceeded:
        signal.setitimer(signal.ITIMER_PROF, 0)
        output.flush()
        channel.send({"type": "end", "ok": False, "error": {
            "code": "CPU_LIMIT", "message": f"limite de CPU ({limits.get('cpu_ms')} ms) excedido"}})
    except bdb.BdbQuit:
        output.flush()
        channel.send({"type": "end", "ok": False,
                      "error": {"code": "ABORTED", "message": "execução parada no depurador"}})
    except Error as e:
        output.flush()
        error = e.as_map()
        error["line"] = _error_line(e, filename)
        error["trace"] = _program_trace(e)
        error["frames"], error["locals"] = _error_frames(e)
        channel.send({"type": "end", "ok": False, "error": error, "profile": profile_of(profiler, channel)})
    except ChannelClosed:
        raise
    except SyntaxError as e:
        output.flush()
        channel.send({"type": "end", "ok": False, "error": {
            "code": "SYNTAX", "message": f"{e.msg}", "line": e.lineno,
            "trace": f"{e.filename} line {e.lineno}: {e.msg}"}})
    except MemoryError:
        channel.send({"type": "end", "ok": False,
                      "error": {"code": "MEMORY", "message": "limite de memória excedido"}})
    except BaseException as e:  # noqa: BLE001 - everything becomes a structured error
        output.flush()
        frames, local_vars = _error_frames(e)
        channel.send({"type": "end", "ok": False, "error": {
            "code": "EXCEPTION",
            "message": f"{type(e).__name__}: {e}",
            "line": _error_line(e, filename),
            "trace": _program_trace(e),
            "frames": frames, "locals": local_vars}, "profile": profile_of(profiler, channel)})


def profile_of(profiler, channel):
    """RF-019-05: where the time went — program/library functions (calls, own and total ms)
    and the time spent waiting for SQL answers."""
    if profiler is None:
        return None
    import pstats
    stats = pstats.Stats(profiler).stats
    rows = []
    for (filename, line, func), (_cc, ncalls, tottime, cumtime, _callers) in stats.items():
        if filename.startswith(FILE_PREFIX):
            rows.append({"where": filename[len(FILE_PREFIX):-1], "line": line, "function": func, "calls": ncalls,
                         "self_ms": round(tottime * 1000, 3), "total_ms": round(cumtime * 1000, 3)})
    rows.sort(key=lambda r: -r["total_ms"])
    return {"functions": rows[:30], "sql_wait_ms": round(channel.sql_seconds * 1000, 3)}


def with_order(params):
    """The declared order survives storage (JSON objects have no order): "order" per parameter."""
    if not isinstance(params, dict):
        return params
    out = {}
    for i, (k, v) in enumerate(params.items()):
        if isinstance(v, dict):
            v = {**v, "order": i}
            if isinstance(v.get("columns"), dict):
                v["columns"] = with_order(v["columns"])  # grid columns keep their order too
        out[k] = v
    return out


def inspect(channel, msg):
    """Check syntax and extract PARAMS/docs without running (RF-005-08)."""
    import ast
    source = msg.get("source", "")
    resp = {"type": "inspection", "ok": True, "params": None,
            "docs": None, "error": None, "has_main": False}
    try:
        tree = ast.parse(source)
    except SyntaxError as e:
        resp.update(ok=False, error={"line": e.lineno, "message": e.msg})
        channel.send(resp)
        return
    resp["docs"] = ast.get_docstring(tree)
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == "main":
            resp["has_main"] = True
            if not resp["docs"]:
                resp["docs"] = ast.get_docstring(node)
        if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == "PARAMS" for t in node.targets):
            try:
                resp["params"] = with_order(ast.literal_eval(node.value))
            except ValueError:
                resp["error"] = {"line": node.lineno, "message": "PARAMS deve ser um literal"}
    resp["lint"] = lint_sql(tree, source)
    channel.send(resp)


# ---------------------------------------------------------------------------
# Static analysis of the program's SQL (spec 019, RF-019-07b)
# ---------------------------------------------------------------------------

SQL_CALLS = {"sql", "sql_one", "sql_value", "sql_exec", "sql_batch"}
TABLE_RE = re.compile(r"\b(?:FROM|JOIN|UPDATE|INTO)\s+([a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*)", re.I)
SQL_RULES = [
    ("select_star", "info", re.compile(r"\bSELECT\s+(DISTINCT\s+)?([A-Z_][A-Z0-9_]*\.)?\*", re.I),
     "SELECT * traz colunas que o programa não usa e quebra quando a tabela muda.",
     "Liste só as colunas usadas."),
    ("leading_wildcard", "warning", re.compile(r"\bI?LIKE\s+'%", re.I),
     "LIKE '%…' (curinga no início) não usa índice: lê a tabela inteira.",
     "Use índice trigram (CREATE EXTENSION pg_trgm; CREATE INDEX … USING gin (coluna gin_trgm_ops)) ou busca textual."),
    ("not_in_subquery", "warning", re.compile(r"\bNOT\s+IN\s*\(\s*SELECT\b", re.I),
     "NOT IN (SELECT …) costuma ser lento e não encontra nada se a subconsulta tiver NULL.",
     "Use NOT EXISTS (SELECT 1 FROM … WHERE …)."),
    ("order_random", "warning", re.compile(r"\bORDER\s+BY\s+RANDOM\s*\(\s*\)", re.I),
     "ORDER BY random() ordena a tabela inteira a cada chamada.",
     "Para amostras use TABLESAMPLE SYSTEM (n) ou sorteie pela chave."),
    ("offset_pagination", "info", re.compile(r"\bOFFSET\b", re.I),
     "Paginação por OFFSET lê e descarta todas as linhas anteriores: cada página fica mais lenta que a outra.",
     "Pagine pela chave: WHERE id > $1 ORDER BY id LIMIT n."),
]
WHERE_FUNC_RE = re.compile(r"\b(LOWER|UPPER|DATE_TRUNC|DATE|TO_CHAR|COALESCE|TRIM|SUBSTRING|EXTRACT|CAST)\s*\(\s*[A-Z_][A-Z0-9_.]*", re.I)
CLAUSE_END_RE = re.compile(r"\b(GROUP\s+BY|ORDER\s+BY|LIMIT|RETURNING|HAVING|UNION)\b", re.I)


def _where_clauses(sql):
    """Each WHERE clause up to the end of its own parenthesis level; FILTER (WHERE …) of
    aggregates is not a row filter and is skipped."""
    out = []
    for m in re.finditer(r"\bWHERE\b", sql, re.I):
        if re.search(r"\bFILTER\s*\(\s*$", sql[:m.start()], re.I):
            continue
        depth, i, rest = 0, m.end(), sql[m.end():]
        end = len(rest)
        for i, ch in enumerate(rest):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth < 0:
                    end = i
                    break
            elif depth == 0 and CLAUSE_END_RE.match(rest, i) and (i == 0 or not rest[i - 1].isalnum()):
                end = i
                break
        out.append(rest[:end])
    return out


def _check_sql(text):
    out = []
    for rule, severity, rx, message, suggestion in SQL_RULES:
        if rx.search(text):
            out.append((rule, severity, message, suggestion))
    head = text.lstrip().split(None, 1)[0].upper() if text.strip() else ""
    wheres = _where_clauses(text)
    if head in ("UPDATE", "DELETE") and not wheres:
        out.append(("no_where", "critical", f"{head} sem WHERE altera a tabela inteira.",
                    "Confirme que é isso mesmo; senão, filtre com WHERE."))
    if any(WHERE_FUNC_RE.search(w) for w in wheres):
        out.append(("function_on_column", "info",
                    "Função sobre coluna no filtro impede o índice comum dessa coluna.",
                    "Crie um índice de expressão (ex.: CREATE INDEX … ON t (lower(col))) ou compare com o valor já transformado."))
    # Only a real table read whole counts (not unnest(…), generate_series(…) or no table at all).
    if head == "SELECT" and not wheres and re.search(r"\bFROM\s+[a-z_][a-z0-9_]*\.[a-z_]", text, re.I) \
            and not re.search(r"\bLIMIT\b", text, re.I):
        out.append(("unbounded_select", "info",
                    "Consulta sem filtro nem LIMIT: o tempo cresce junto com a tabela.",
                    "Filtre (WHERE), pagine (LIMIT) ou leia de uma visão resumida."))
    return out


LINT_OK_RE = re.compile(r"#\s*ana:lint-ok\s+([a-z_,\s]+?)\s*(?:[—-]|$)")


def lint_sql(tree, source=""):
    """Findings: [{line, rule, severity, message, suggestion, sql, tables}].

    `# ana:lint-ok rule[, rule] — reason` on the call's lines (or the line above) accepts a
    finding on purpose (e.g. LIKE '%x%' backed by a trigram index)."""
    import ast
    findings = []
    accepted = {}
    for n, text in enumerate(source.splitlines(), start=1):
        m = LINT_OK_RE.search(text)
        if m:
            accepted[n] = {r.strip() for r in m.group(1).split(",") if r.strip()}
    loops = (ast.For, ast.AsyncFor, ast.While)
    comps = (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)

    def add(node, rule, severity, message, suggestion, text=""):
        span = range(node.lineno - 1, (getattr(node, "end_lineno", None) or node.lineno) + 1)
        if any(rule in accepted.get(n, ()) for n in span):
            return
        findings.append({"line": node.lineno, "rule": rule, "severity": severity, "message": message,
                         "suggestion": suggestion, "sql": " ".join(text.split())[:200],
                         "tables": sorted({t.lower() for t in TABLE_RE.findall(text)})})

    def visit(node, in_loop, params=frozenset()):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            a = node.args
            params = frozenset(x.arg for x in a.posonlyargs + a.args + a.kwonlyargs) \
                | ({a.vararg.arg} if a.vararg else set()) | ({a.kwarg.arg} if a.kwarg else set())
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in SQL_CALLS \
                and isinstance(node.func.value, ast.Name) and node.func.value.id == "ana" and node.args:
            arg = node.args[0]
            text = ""
            if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                text = arg.value
            elif isinstance(arg, ast.JoinedStr) and any(isinstance(v, ast.FormattedValue) for v in arg.values) \
                    or isinstance(arg, ast.BinOp) and isinstance(arg.op, (ast.Add, ast.Mod)) and not _all_literal(arg) \
                    or isinstance(arg, ast.Call) and isinstance(arg.func, ast.Attribute) and arg.func.attr == "format":
                text = _literal_parts(arg)
                used = {n.id for n in ast.walk(arg) if isinstance(n, ast.Name)}
                if used & params:
                    add(node, "dynamic_sql", "serious",
                        "Valor recebido pela função entra no texto do SQL: risco de injeção de SQL e o plano não é reaproveitado.",
                        "Passe os valores como parâmetros ($1, $2…); para nomes de colunas, escolha de uma lista fixa.", text)
                else:
                    add(node, "dynamic_sql", "warning",
                        "SQL montado a partir de valores do próprio código (ex.: lista de colunas): seguro só se nada vier do usuário.",
                        "Confirme a origem dos valores; quando der, prefira texto fixo com parâmetros ($1, $2…).", text)
            elif isinstance(arg, ast.BinOp):
                text = _literal_parts(arg)
            if in_loop and node.func.attr != "sql_batch":
                add(node, "sql_in_loop", "warning",
                    "Consulta dentro de laço: uma ida ao banco por item (N+1) — fica lenta com volume.",
                    "Use ana.sql_batch para gravar em lote, ou leia tudo de uma vez com WHERE id = ANY($1) / JOIN.", text)
            for rule, severity, message, suggestion in _check_sql(text) if text else []:
                add(node, rule, severity, message, suggestion, text)
        if isinstance(node, loops):
            for field, value in ast.iter_fields(node):
                inner = in_loop or field in ("body", "orelse", "test") and not (isinstance(node, (ast.For, ast.AsyncFor)) and field == "orelse")
                for child in (value if isinstance(value, list) else [value]):
                    if isinstance(child, ast.AST):
                        visit(child, inner, params)
            return
        if isinstance(node, comps):
            # The first iterable is evaluated once, outside the loop: {r["id"]: r for r in ana.sql(...)}.
            first = node.generators[0]
            visit(first.iter, in_loop, params)
            for child in ast.iter_child_nodes(node):
                if child is first:
                    visit(first.target, True, params)
                    for cond in first.ifs:
                        visit(cond, True, params)
                elif isinstance(child, ast.AST):
                    visit(child, True, params)
            return
        for child in ast.iter_child_nodes(node):
            visit(child, in_loop, params)

    visit(tree, False)
    return sorted(findings, key=lambda f: (f["line"], f["rule"]))


def _all_literal(node):
    """Text built only from fixed pieces ("a" + "b", "x" if flag else "") is still fixed text."""
    import ast
    if isinstance(node, ast.Constant):
        return True
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        return _all_literal(node.left) and _all_literal(node.right)
    if isinstance(node, ast.IfExp):
        return _all_literal(node.body) and _all_literal(node.orelse)
    return False


def _literal_parts(node):
    """The literal text of a SQL built from pieces (enough to apply the text rules)."""
    import ast
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        return "".join(v.value if isinstance(v, ast.Constant) else " ? " for v in node.values)
    if isinstance(node, ast.BinOp):
        return _literal_parts(node.left) + " " + _literal_parts(node.right)
    if isinstance(node, ast.IfExp):
        return _literal_parts(node.body)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
        return _literal_parts(node.func.value)
    return " ? "


def entry_point():
    memory = int(os.environ.get("ANA_PY_MEMORY_MB", "512"))
    cpu = int(os.environ.get("ANA_PY_CPU_S", "3600"))
    output_limit = int(os.environ.get("ANA_OUTPUT_MAX_KB", "512")) * 1024

    # The protocol uses copies of fds 0/1; the originals are neutralized so that
    # accidental writes to fd 1 (e.g. C extensions) cannot corrupt frames.
    stream_in = os.fdopen(os.dup(0), "rb", buffering=0)
    stream_out = os.fdopen(os.dup(1), "wb", buffering=0)
    null = os.open(os.devnull, os.O_RDWR)
    os.dup2(null, 0)
    os.dup2(2, 1)
    sys.stdin = open(os.devnull, "r")

    apply_limits(memory, cpu)
    channel = Channel(stream_in, stream_out)
    try:
        channel.send({"type": "ready", "pid": os.getpid()})
        msg = channel.receive()
        kind = msg.get("type")
        if kind == "run":
            run(channel, msg, output_limit)
        elif kind == "inspect":
            inspect(channel, msg)
    except ChannelClosed:
        pass
    finally:
        sys.stdout = sys.__stdout__
        os._exit(0)


if __name__ == "__main__":
    entry_point()
