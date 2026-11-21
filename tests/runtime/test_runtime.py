# SPDX-FileCopyrightText: 2026 LE Devices
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for the isolated Python runtime (specs 002 and 004), no database.

A "fake core" speaks the protocol with the runtime process and answers its
requests with test functions. Run: python3 -m unittest discover -s tests/runtime
"""

import json
import os
import struct
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUNTIME = os.path.join(ROOT, "priv", "python", "ana_runtime.py")


class FakeCore:
    def __init__(self, handler=None, env=None):
        self.handler = handler or (lambda op, args: None)
        self.proc = subprocess.Popen(
            [sys.executable, "-I", RUNTIME],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env if env is not None else {"PATH": os.environ.get("PATH", "")})
        ready = self.receive()
        assert ready["type"] == "ready", ready

    def send(self, msg):
        data = json.dumps(msg).encode()
        self.proc.stdin.write(struct.pack(">I", len(data)) + data)
        self.proc.stdin.flush()

    def receive(self):
        head = self.proc.stdout.read(4)
        if len(head) < 4:
            raise EOFError(self.proc.stderr.read().decode())
        (n,) = struct.unpack(">I", head)
        return json.loads(self.proc.stdout.read(n))

    def run(self, source, params=None, **extra):
        msg = {"type": "run", "program": "test.prog", "version": 1,
               "source": source, "params": params or {},
               "context": {"user": "tester", "execution_id": "x"}}
        msg.update(extra)
        self.send(msg)

    def until(self, types, events=None):
        """Read messages, answering requests, until one of `types` arrives."""
        while True:
            m = self.receive()
            if events is not None:
                events.append(m)
            if m["type"] == "request":
                try:
                    value = self.handler(m["op"], m["args"])
                    self.send({"type": "response", "id": m["id"], "ok": True, "value": value})
                except Exception as e:  # noqa: BLE001
                    self.send({"type": "response", "id": m["id"], "ok": False,
                               "error": {"code": "SQL", "message": str(e),
                                         "sqlstate": getattr(e, "sqlstate", "42501")}})
                continue
            if m["type"] in types:
                return m

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        self.proc.wait(timeout=5)
        self.proc.stdout.close()
        self.proc.stderr.close()


def run(source, params=None, handler=None, **extra):
    core = FakeCore(handler)
    events = []
    try:
        core.run(source, params, **extra)
        end = core.until({"end"}, events)
        return end, events
    finally:
        core.close()


class TestExecution(unittest.TestCase):
    def test_ca_002_01_sum(self):
        end, _ = run("def main(a, b):\n    return a + b\n", {"a": 2, "b": 3})
        self.assertTrue(end["ok"], end)
        self.assertEqual(end["result"], 5)

    def test_rf_002_06_print_goes_to_output(self):
        end, ev = run("def main():\n    print('olá')\n    return 1\n")
        texts = [e["data"] for e in ev if e["type"] == "output" and e["kind"] == "text"]
        self.assertIn("olá\n", "".join(texts))

    def test_rf_002_05_table_and_log(self):
        source = ("def main():\n"
                  "    ana.log('hi', 'warning')\n"
                  "    ana.table([{'a': 1}, {'a': 2, 'b': 3}], title='T')\n")
        end, ev = run(source)
        self.assertTrue(end["ok"], end)
        tab = [e for e in ev if e.get("kind") == "table"][0]["data"]
        self.assertEqual(tab["columns"], ["a", "b"])
        self.assertEqual(tab["rows"], [[1, None], [2, 3]])

    def test_rf_021_10_rich_outputs(self):
        source = ("import datetime\n"
                  "def main():\n"
                  "    act = {'label': 'Apontar', 'program': 'projects.log_time', 'params': {'task': '1'},\n"
                  "           'ask': {'hours': {'type': 'decimal'}}, 'ignored': 1}\n"
                  "    ana.metrics([{'label': 'L', 'value': 1, 'status': 'ok'}])\n"
                  "    ana.board([{'key': 'todo', 'label': 'A fazer'}], [{'column': 'todo', 'title': 'x', 'actions': [act]}])\n"
                  "    ana.gantt([{'code': '1', 'name': 'n', 'start': datetime.date(2031, 3, 3),\n"
                  "                'finish': datetime.date(2031, 3, 7), 'critical': True}])\n"
                  "    ana.tabs([{'label': 'Quadro', 'program': 'p', 'params': {'view': 'board'}, 'open': True}], 'board')\n"
                  "    ana.table([{'a': 1, '_actions': [act]}, {'a': 2}])\n"
                  "    ana.actions([act])\n")
        end, ev = run(source)
        self.assertTrue(end["ok"], end)
        out = {e["kind"]: e["data"] for e in ev if e["type"] == "output"}
        self.assertEqual(set(out), {"metrics", "board", "gantt", "tabs", "table", "actions"})
        self.assertEqual(out["gantt"]["items"][0]["start"], "2031-03-03")
        self.assertEqual(out["table"]["columns"], ["a"])
        self.assertEqual(out["table"]["row_actions"][1], [])
        self.assertNotIn("ignored", out["actions"]["items"][0])        # only known action keys pass
        end, _ = run("def main():\n    ana.actions([{'label': 'x'}])\n")
        self.assertFalse(end["ok"])
        self.assertEqual(end["error"]["code"], "INVALID_PARAMETER")

    def test_rf_035_01_rows_that_open_a_document(self):
        source = ("def main():\n"
                  "    ana.table([{'doc': 'ORD-1', '_open': {'program': 'docs.view', 'params': {'kind': 'order', 'key': '1'}}},\n"
                  "               {'doc': 'avulso'}])\n")
        end, ev = run(source)
        self.assertTrue(end["ok"], end)
        t = [e["data"] for e in ev if e["type"] == "output" and e["kind"] == "table"][0]
        self.assertEqual(t["columns"], ["doc"])                          # _open is not a column
        self.assertEqual(t["row_open"][0], {"label": "Abrir", "program": "docs.view",
                                            "params": {"kind": "order", "key": "1"}, "open": True})
        self.assertIsNone(t["row_open"][1])
        self.assertNotIn("row_actions", t)

    def test_ca_026_02_03_chart_validation_and_other(self):
        source = ("def main():\n"
                  "    x = ['a', 'b']\n"
                  "    ana.chart(type='line', x=x, series=[{'name': f's{i}', 'values': [i, i + 1]} for i in range(10)])\n"
                  "    ana.chart(type='donut', x=list('abcdefgh'), series=[{'name': 'p', 'values': [8, 7, 6, 5, 4, 3, 2, 1]}])\n")
        end, ev = run(source)
        self.assertTrue(end["ok"], end)
        line, donut = [e["data"] for e in ev if e.get("kind") == "chart"]
        self.assertEqual(len(line["series"]), 8)
        self.assertEqual(line["series"][-1]["name"], "Outros")
        self.assertEqual(line["series"][-1]["values"], [3.0, 6.0])   # the three smallest series (0, 1, 2) summed
        self.assertEqual(donut["x"][-1], "Outros")
        self.assertEqual(donut["series"][0]["values"][-1], 6.0)
        for bad in ("ana.chart(type='pie', x=[1], series=[{'name': 'a', 'values': [1]}])",
                    "ana.chart(type='line', x=[1, 2], series=[{'name': 'a', 'values': [1]}])",
                    "ana.chart(type='line', x=[1], series=[{'name': 'a', 'values': ['x']}])"):
            end, _ = run("def main():\n    " + bad + "\n")
            self.assertEqual(end["error"]["code"], "INVALID_PARAMETER", bad)

    def test_rf_002_05_typed_sql(self):
        def handler(op, args):
            self.assertEqual(op, "sql")
            self.assertEqual(args["params"], [7, "1.50"])
            return {"columns": [{"name": "price", "type": "numeric"},
                                {"name": "day", "type": "date"}],
                    "rows": [["10.25", "2026-10-02"]]}
        source = ("from decimal import Decimal\n"
                  "def main():\n"
                  "    r = ana.sql_one('select', 7, Decimal('1.50'))\n"
                  "    assert r['price'] == Decimal('10.25')\n"
                  "    return [str(r['price'] * 2), r['day'].year]\n")
        end, _ = run(source, handler=handler)
        self.assertTrue(end["ok"], end)
        self.assertEqual(end["result"], ["20.50", 2026])

    def test_decimal_result_is_text(self):
        end, _ = run("from decimal import Decimal\ndef main():\n    return Decimal('2.000')\n")
        self.assertEqual(end["result"], "2.000")

    def test_rf_002_05_business_error(self):
        end, _ = run("def main():\n    raise ana.Error('NO_BALANCE', 'missing')\n")
        self.assertFalse(end["ok"])
        self.assertEqual(end["error"]["code"], "NO_BALANCE")
        self.assertEqual(end["error"]["line"], 2)

    def test_sql_error_is_catchable(self):
        def handler(op, args):
            raise RuntimeError("permission denied")
        source = ("def main():\n"
                  "    try:\n"
                  "        ana.sql('select * from ana_system.app_user')\n"
                  "    except ana.SqlError as e:\n"
                  "        return e.sqlstate\n")
        end, _ = run(source, handler=handler)
        self.assertEqual(end["result"], "42501")

    def test_database_rule_keeps_its_code(self):
        class Violation(Exception):
            sqlstate = "23514"

        def handler(op, args):
            raise Violation("OVER_RECEIPT: recebido 11 acima do pedido 10")
        end, _ = run("def main():\n    ana.sql_exec('update x set y = 1')\n", handler=handler)
        self.assertEqual((end["error"]["code"], end["error"]["message"]),
                         ("OVER_RECEIPT", "recebido 11 acima do pedido 10"))
        source = ("def main():\n    try:\n        ana.sql('x')\n    except ana.SqlError as e:\n"
                  "        return [e.code, e.sqlstate]\n")
        end, _ = run(source, handler=handler)
        self.assertEqual(end["result"], ["OVER_RECEIPT", "23514"])           # still an ana.SqlError

    def test_python_exception_becomes_structured_error(self):
        end, _ = run("def main():\n    return 1/0\n")
        self.assertEqual(end["error"]["code"], "EXCEPTION")
        self.assertIn("ZeroDivisionError", end["error"]["message"])
        self.assertNotIn("ana_runtime", end["error"]["trace"])

    def test_syntax(self):
        end, _ = run("def main(:\n")
        self.assertEqual(end["error"]["code"], "SYNTAX")

    def test_no_main(self):
        end, _ = run("x = 1\n")
        self.assertEqual(end["error"]["code"], "NO_MAIN")

    def test_invalid_result(self):
        end, _ = run("def main():\n    return object()\n")
        self.assertEqual(end["error"]["code"], "INVALID_RESULT")

    def test_nested_call(self):
        def handler(op, args):
            self.assertEqual(op, "call")
            return args["params"]["x"] * 10
        end, _ = run("def main():\n    return ana.call('other.prog', x=4)\n", handler=handler)
        self.assertEqual(end["result"], 40)

    def test_savepoint_requests(self):
        calls = []

        def handler(op, args):
            calls.append((op, args.get("action")))
            if args.get("action") == "create":
                return "ana_sp_1"
            return True
        source = ("def main():\n"
                  "    try:\n"
                  "        with ana.savepoint():\n"
                  "            raise ana.Error('X')\n"
                  "    except ana.Error:\n"
                  "        pass\n"
                  "    return 1\n")
        end, _ = run(source, handler=handler)
        self.assertTrue(end["ok"], end)
        self.assertEqual(calls, [("savepoint", "create"), ("savepoint", "rollback")])

    def test_rf_002_07_imports_library(self):
        def handler(op, args):
            self.assertEqual(op, "library_source")
            if args["name"] == "util":
                return {"source": None, "package": True}
            if args["name"] == "util.format":
                return {"source": "def money(v):\n    return f'R$ {v:.2f}'\n"}
            return {"source": None, "package": False}
        source = ("from ana_lib.util.format import money\n"
                  "def main():\n    return money(3)\n")
        end, _ = run(source, handler=handler)
        self.assertTrue(end["ok"], end)
        self.assertEqual(end["result"], "R$ 3.00")

    def test_rnf_002_01_no_credentials_in_environment(self):
        end, _ = run("import os\ndef main():\n    return sorted(os.environ)\n")
        self.assertNotIn("ANA_DB_PASSWORD", end["result"])

    def test_rnf_002_01_no_fork(self):
        if os.getuid() == 0:
            self.skipTest("RLIMIT_NPROC does not apply to root")
        end, _ = run("import os\ndef main():\n    return os.fork()\n")
        self.assertFalse(end["ok"])

    def test_rnf_002_06_output_truncated(self):
        core = FakeCore(env={"PATH": os.environ.get("PATH", ""), "ANA_OUTPUT_MAX_KB": "1"})
        ev = []
        try:
            core.run("def main():\n    for i in range(500):\n        print('x' * 50)\n")
            end = core.until({"end"}, ev)
        finally:
            core.close()
        self.assertTrue(end["ok"])
        total = sum(len(e["data"]) for e in ev if e.get("kind") == "text")
        self.assertLessEqual(total, 1024)
        self.assertTrue(any(e.get("kind") == "log" for e in ev))


class TestLimits(unittest.TestCase):
    def test_ca_012_01_cpu_limit(self):
        end, _ = run("def main():\n    while True:\n        pass\n", limits={"cpu_ms": 300})
        self.assertEqual(end["error"]["code"], "CPU_LIMIT")
        self.assertGreaterEqual(end["usage"]["cpu_ms"], 250)

    def test_cpu_limit_not_swallowed_by_except_exception(self):
        source = ("def main():\n"
                  "    try:\n"
                  "        while True:\n"
                  "            pass\n"
                  "    except Exception:\n"
                  "        return 'swallowed'\n")
        end, _ = run(source, limits={"cpu_ms": 200})
        self.assertEqual(end["error"]["code"], "CPU_LIMIT")

    def test_ca_012_02_memory_limit(self):
        end, _ = run("def main():\n    x = bytearray(400 * 1024 * 1024)\n    return len(x)\n",
                     limits={"memory_mb": 128})
        self.assertEqual(end["error"]["code"], "MEMORY")

    def test_ca_012_08_usage_reported(self):
        end, _ = run("def main():\n    return sum(range(100000))\n", limits={"cpu_ms": 5000})
        self.assertTrue(end["ok"])
        self.assertIn("cpu_ms", end["usage"])
        self.assertGreater(end["usage"]["max_rss_kb"], 0)

    def test_output_limit_from_execution(self):
        end, ev = run("def main():\n    for i in range(200):\n        print('y' * 50)\n", limits={"output_kb": 1})
        total = sum(len(e["data"]) for e in ev if e.get("kind") == "text")
        self.assertLessEqual(total, 1024)


class TestParams(unittest.TestCase):
    SOURCE = ('PARAMS = {"a": {"type": "int", "required": True},\n'
              '          "d": {"type": "date"},\n'
              '          "f": {"type": "bool", "default": False}}\n'
              'def main(a, d=None, f=False):\n'
              '    return [a, d.isoformat() if d else None, f]\n')

    def test_ca_002_04_required_missing(self):
        end, _ = run(self.SOURCE, {})
        self.assertEqual(end["error"]["code"], "INVALID_PARAMETER")

    def test_conversion(self):
        end, _ = run(self.SOURCE, {"a": "5", "d": "2026-01-31"})
        self.assertEqual(end["result"], [5, "2026-01-31", False])

    def test_unknown(self):
        end, _ = run(self.SOURCE, {"a": 1, "zzz": 2})
        self.assertEqual(end["error"]["code"], "INVALID_PARAMETER")

    def test_wrong_type(self):
        end, _ = run(self.SOURCE, {"a": "abc"})
        self.assertEqual(end["error"]["code"], "INVALID_PARAMETER")

    def test_042_b02_rows_of_a_list_with_columns(self):
        source = ('PARAMS = {"lines": {"type": "list", "label": "itens contados", "columns": {\n'
                  '    "product": {"type": "str", "required": True, "label": "item"},\n'
                  '    "counted": {"type": "decimal", "required": True, "label": "quantidade contada"}}}}\n'
                  'def main(lines):\n    return [l["counted"] for l in lines]\n')
        end, _ = run(source, {"lines": [{"product": "A", "counted": "2,5"}]})
        self.assertEqual(end["result"], ["2,5"])                            # values are not changed
        end, _ = run(source, {"lines": [{"product": "A", "counted": 1}, {"product": "B", "quantity": 3}]})
        self.assertEqual(end["error"]["code"], "INVALID_PARAMETER")
        self.assertIn("itens contados, linha 2: falta quantidade contada", end["error"]["message"])
        end, _ = run(source, {"lines": [{"product": "A", "counted": "muito"}]})
        self.assertIn("linha 1: quantidade contada não é do tipo decimal", end["error"]["message"])
        end, _ = run(source, {"lines": ["A"]})
        self.assertIn("linha 1: deve ser um objeto", end["error"]["message"])
        one = ('PARAMS = {"terms": {"type": "list", "columns": {"term": {"type": "str", "required": True}}}}\n'
               'def main(terms):\n    return terms\n')
        end, _ = run(one, {"terms": ["AVISTA", {"term": "PIX"}]})
        self.assertEqual(end["result"], ["AVISTA", {"term": "PIX"}])           # a single column accepts plain values

    def test_decimal_accepts_brazilian_notation(self):
        # Spec 031 usability: operators type "4,79" or "1.234,56" in money/quantity fields.
        source = ('PARAMS = {"v": {"type": "decimal"}}\n'
                  'def main(v):\n    return str(v)\n')
        for typed, expected in (("4,79", "4.79"), ("1.234,56", "1234.56"), ("12.5", "12.5"), (3, "3")):
            end, _ = run(source, {"v": typed})
            self.assertEqual(end["result"], expected, typed)


class TestInspection(unittest.TestCase):
    def inspect(self, source):
        core = FakeCore()
        try:
            core.send({"type": "inspect", "source": source})
            return core.receive()
        finally:
            core.close()

    def test_rf_005_08_syntax_error_with_line(self):
        r = self.inspect("x = 1\ndef main(:\n")
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"]["line"], 2)

    def test_extracts_params(self):
        r = self.inspect('"""Doc."""\nPARAMS = {"a": {"type": "int"}}\ndef main(a): pass\n')
        self.assertEqual(r["params"], {"a": {"type": "int", "order": 0}})   # declared order kept
        self.assertEqual(r["docs"], "Doc.")
        self.assertTrue(r["has_main"])

    def test_grid_columns_keep_declared_order(self):
        # JSON objects lose order on storage: the items grid needs "order" per column too.
        r = self.inspect('PARAMS = {"items": {"type": "list", "columns": {"product": {}, "quantity": {}, "price": {}}}}\n'
                         'def main(items): pass\n')
        cols = r["params"]["items"]["columns"]
        self.assertEqual([cols[c]["order"] for c in ("product", "quantity", "price")], [0, 1, 2])

    def test_lint_ok_marker_accepts_a_finding_on_purpose(self):
        r = self.inspect("def main(q):\n"
                         "    # ana:lint-ok leading_wildcard — trigram index\n"
                         "    a = ana.sql(\"SELECT id FROM t WHERE name ILIKE '%' || $1 || '%' LIMIT 10\", q)\n"
                         "    b = ana.sql(\"SELECT id FROM t WHERE name ILIKE '%' || $1 || '%' LIMIT 10\", q)\n")
        self.assertEqual([(f["line"], f["rule"]) for f in r["lint"]], [(4, "leading_wildcard")])

    def test_lint_rules_are_precise(self):
        r = self.inspect(
            "def main(ids):\n"
            "    ana.sql('SELECT x FROM unnest($1::int[]) AS u(x) JOIN s.t ON t.id = u.x', ids)\n"          # 2: bounded by unnest
            "    ana.sql('SELECT (SELECT count(*) FROM s.a WHERE a.k = $1) AS n, "
            "(SELECT COALESCE(sum(v), 0) FROM s.b WHERE b.k = $1) AS m', 1)\n"                              # 3: no function in WHERE
            "    ana.sql('SELECT sum(v) FILTER (WHERE lower(c) = $1) FROM s.t', 'x')\n"                     # 4: FILTER is not a WHERE
            "    ana.sql('SELECT id FROM s.t WHERE lower(name) = $1', 'x')\n")                              # 5: real one
        got = sorted((f["line"], f["rule"]) for f in r["lint"])
        self.assertEqual(got, [(4, "unbounded_select"), (5, "function_on_column")])

    def test_lint_comprehension_source_runs_once(self):
        r = self.inspect("def main(ids):\n"
                         "    a = {x['id']: x for x in ana.sql('SELECT id FROM t WHERE id = ANY($1)', ids)}\n"
                         "    b = [ana.sql_one('SELECT id FROM t WHERE id = $1', i) for i in ids]\n")
        loops = [f["line"] for f in r["lint"] if f["rule"] == "sql_in_loop"]
        self.assertEqual(loops, [3])


DEBUGGABLE = ("def main():\n"      # 1
              "    x = 10\n"       # 2
              "    y = x + 1\n"    # 3
              "    z = y * 2\n"    # 4
              "    return z\n")    # 5


class TestDebugger(unittest.TestCase):
    def setUp(self):
        self.core = FakeCore()

    def tearDown(self):
        self.core.close()

    def debug(self, source=DEBUGGABLE, breakpoints=(3,), **extra):
        self.core.run(source, debug=True, breakpoints=list(breakpoints), **extra)
        return self.core.until({"pause", "end"})

    def cmd(self, action, **extra):
        self.core.send(dict(type="debug", action=action, **extra))

    def test_ca_004_01_stops_at_breakpoint(self):
        p = self.debug()
        self.assertEqual(p["type"], "pause")
        self.assertEqual(p["line"], 3)
        self.assertEqual(p["reason"], "breakpoint")
        names = {v["name"]: v["value"] for v in p["variables"]}
        self.assertEqual(names, {"x": "10"})
        self.assertEqual(p["stack"][0]["function"], "main")

    def test_ca_004_02_over_and_continue(self):
        self.debug()
        self.cmd("over")
        p = self.core.until({"pause", "end"})
        self.assertEqual(p["line"], 4)
        self.cmd("continue")
        end = self.core.until({"pause", "end"})
        self.assertEqual(end["type"], "end")
        self.assertEqual(end["result"], 22)

    def test_ca_004_03_eval_keeps_paused(self):
        self.debug()
        self.cmd("eval", expression="x * 2")
        a = self.core.until({"eval"})
        self.assertTrue(a["ok"])
        self.assertEqual(a["value"], "20")
        self.cmd("eval", expression="does_not_exist")
        a = self.core.until({"eval"})
        self.assertFalse(a["ok"])
        self.cmd("continue")
        self.assertEqual(self.core.until({"end"})["result"], 22)

    def test_stop(self):
        self.debug()
        self.cmd("stop")
        end = self.core.until({"end"})
        self.assertEqual(end["error"]["code"], "ABORTED")

    def test_rf_004_06_stop_on_entry(self):
        p = self.debug(breakpoints=(), stop_on_entry=True)
        self.assertEqual(p["line"], 2)

    def test_into_and_out(self):
        source = ("def double(v):\n"       # 1
                  "    r = v * 2\n"        # 2
                  "    return r\n"         # 3
                  "def main():\n"          # 4
                  "    a = double(3)\n"    # 5
                  "    return a\n")        # 6
        p = self.debug(source, breakpoints=(5,))
        self.assertEqual(p["line"], 5)
        self.cmd("into")
        p = self.core.until({"pause"})
        self.assertEqual((p["function"], p["line"]), ("double", 2))
        self.assertEqual([q["function"] for q in p["stack"]], ["double", "main"])
        self.cmd("out")
        p = self.core.until({"pause"})
        self.assertEqual(p["function"], "main")
        self.cmd("continue")
        self.assertEqual(self.core.until({"end"})["result"], 6)

    def test_breakpoints_while_paused(self):
        self.debug(breakpoints=(2,))
        self.cmd("breakpoints", lines=[5, 999])
        r = self.core.until({"breakpoints"})
        self.assertEqual(r["lines"], [5])
        self.cmd("continue")
        p = self.core.until({"pause"})
        self.assertEqual(p["line"], 5)
        self.cmd("continue")
        self.core.until({"end"})

    def test_no_breakpoints_runs_straight(self):
        p = self.debug(breakpoints=())
        self.assertEqual(p["type"], "end")
        self.assertEqual(p["result"], 22)


if __name__ == "__main__":
    unittest.main()
