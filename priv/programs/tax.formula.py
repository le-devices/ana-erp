# ana:description Linguagem de fórmulas fechada do motor de impostos: validação e avaliação em decimal
# ana:kind library
"""Closed formula language of the tax engine (spec 049, D4, RF-049-04, CA-049-05).

A formula is a Python *expression* parsed with `ast` and accepted only when every node is in an allow-list:
numbers, texts, names (document paths such as `emitter.regime` or earlier formulas of the same rule),
arithmetic, comparisons, boolean logic, `x if c else y` and a fixed set of generic functions. Nothing else:
no attribute of objects, no subscripts, no lambdas, no comprehensions, no unknown calls. Numbers are Decimal
(RNF-049-02): literals are read from the source text, never through binary floating point.

The language knows no tax and no regime (P21): the engine supplies the generic functions
(table, bracket, indicator, tax) at evaluation time.
"""

import ast
from decimal import Decimal, ROUND_HALF_UP, ROUND_FLOOR, ROUND_CEILING, InvalidOperation

ROOTS = ("doc", "emitter", "recipient", "contract", "item")
# Short names for the current item (or the document, for document-scope taxes).
SHORT = ("amount", "quantity", "unit_price", "discount", "total")
# name: (min args, max args)
FUNCTIONS = {
    "round": (1, 2), "floor": (1, 2), "ceil": (1, 2), "min": (2, 20), "max": (2, 20), "abs": (1, 1),
    "has": (1, 1), "table": (2, 3), "bracket": (4, 4), "indicator": (1, 1), "tax": (2, 2),
}
OUTPUTS = ("base", "rate", "amount", "withheld", "credit", "charged")
MAX_LENGTH = 2000

_BINOPS = {ast.Add: "+", ast.Sub: "-", ast.Mult: "*", ast.Div: "/"}
_CMPOPS = (ast.Eq, ast.NotEq, ast.Lt, ast.LtE, ast.Gt, ast.GtE, ast.In, ast.NotIn)


class FormulaError(Exception):
    def __init__(self, message, formula=None, column=None):
        super().__init__(message)
        self.message = message
        self.formula = formula
        self.column = column

    def text(self):
        where = f"fórmula {self.formula}" if self.formula else "fórmula"
        if self.column is not None:
            where += f", posição {self.column + 1}"
        return f"{where}: {self.message}"


def _path(node):
    """`emitter.regime` → "emitter.regime"; None when it is not a plain dotted name."""
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
        return ".".join(reversed(parts))
    return None


class _Checker(ast.NodeVisitor):
    def __init__(self, source, known, paths):
        self.source = source
        self.known = known          # earlier formula names
        self.paths = paths          # optional set of valid document paths (None = only the root is checked)

    def fail(self, node, message):
        raise FormulaError(message, column=getattr(node, "col_offset", None))

    def generic_visit(self, node):
        self.fail(node, f"construção não permitida ({type(node).__name__})")

    def visit_Expression(self, node):
        self.visit(node.body)

    def visit_Constant(self, node):
        if not isinstance(node.value, (int, float, str, bool)) and node.value is not None:
            self.fail(node, "valor não permitido")

    def visit_Name(self, node):
        self._name(node, node.id)

    def visit_Attribute(self, node):
        p = _path(node)
        if p is None:
            self.fail(node, "só caminhos do documento usam ponto (ex.: emitter.regime)")
        self._name(node, p)

    def _name(self, node, name):
        root = name.split(".")[0]
        if name in self.known or name in SHORT or name in ("True", "False", "None"):
            return
        if root not in ROOTS:
            self.fail(node, f"nome desconhecido: {name}")
        if "." not in name:
            self.fail(node, f"informe o campo: {name}.<campo>")
        if self.paths is not None and name not in self.paths and not name.startswith("doc."):
            self.fail(node, f"campo desconhecido: {name}")

    def visit_BinOp(self, node):
        if type(node.op) not in _BINOPS:
            self.fail(node, "operador não permitido (use + - * /)")
        self.visit(node.left)
        self.visit(node.right)

    def visit_UnaryOp(self, node):
        if not isinstance(node.op, (ast.USub, ast.UAdd, ast.Not)):
            self.fail(node, "operador não permitido")
        self.visit(node.operand)

    def visit_BoolOp(self, node):
        for v in node.values:
            self.visit(v)

    def visit_Compare(self, node):
        for op in node.ops:
            if not isinstance(op, _CMPOPS):
                self.fail(node, "comparação não permitida")
        self.visit(node.left)
        for c in node.comparators:
            self.visit(c)

    def visit_IfExp(self, node):
        self.visit(node.test)
        self.visit(node.body)
        self.visit(node.orelse)

    def visit_Tuple(self, node):
        for e in node.elts:
            self.visit(e)

    visit_List = visit_Tuple

    def visit_Call(self, node):
        if not isinstance(node.func, ast.Name) or node.func.id not in FUNCTIONS:
            name = _path(node.func) or "?"
            self.fail(node, f"função desconhecida: {name}")
        if node.keywords:
            self.fail(node, "funções recebem só argumentos por posição")
        lo, hi = FUNCTIONS[node.func.id]
        if not lo <= len(node.args) <= hi:
            self.fail(node, f"{node.func.id} recebe de {lo} a {hi} argumento(s)")
        if node.func.id == "has" and not (isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str)):
            self.fail(node, "has recebe o caminho entre aspas, ex.: has('item.ncm')")
        for a in node.args:
            if isinstance(a, ast.Starred):
                self.fail(a, "construção não permitida")
            self.visit(a)


def parse(source, known=(), paths=None):
    """Validated expression tree; raises FormulaError with the column of the problem."""
    if not isinstance(source, str) or not source.strip():
        raise FormulaError("fórmula vazia")
    if len(source) > MAX_LENGTH:
        raise FormulaError(f"fórmula com mais de {MAX_LENGTH} caracteres")
    text = source.strip()
    try:
        tree = ast.parse(text, mode="eval")
    except SyntaxError as e:
        raise FormulaError(f"sintaxe inválida ({e.msg})", column=(e.offset or 1) - 1) from None
    _Checker(text, set(known), paths).visit(tree)
    return _Compiled(text, tree)


def validate(formulas, paths=None):
    """formulas: [[name, expression], ...] in order. Returns the compiled list; raises FormulaError."""
    if not isinstance(formulas, list) or not formulas:
        raise FormulaError("informe ao menos uma fórmula")
    seen, out = [], []
    for item in formulas:
        if not (isinstance(item, (list, tuple)) and len(item) == 2 and isinstance(item[0], str)):
            raise FormulaError("cada fórmula é [nome, expressão]")
        name, expr = item
        if (not name.isidentifier() or name in FUNCTIONS or name in ROOTS or name.startswith("_")
                or (name in SHORT and name not in OUTPUTS)):
            raise FormulaError(f"nome de fórmula inválido: {name}", formula=name)
        if name in seen:
            raise FormulaError(f"fórmula repetida: {name}", formula=name)
        try:
            out.append((name, parse(expr, seen, paths)))
        except FormulaError as e:
            e.formula = name
            raise
        seen.append(name)
    if not {"amount", "withheld", "credit", "charged"} & set(seen):
        raise FormulaError("a regra precisa de amount, withheld, credit ou charged")
    return out


# --------------------------------------------------------------------------- evaluation

def dec(v):
    if isinstance(v, Decimal):
        return v
    if isinstance(v, bool) or v is None:
        raise FormulaError("valor não numérico")
    if isinstance(v, int):
        return Decimal(v)
    if isinstance(v, float):
        return Decimal(repr(v))
    try:
        return Decimal(str(v))
    except InvalidOperation:
        raise FormulaError(f"valor não numérico: {v!r}") from None


def _quant(n):
    return Decimal(1).scaleb(-int(n))


def _round(x, n=0, mode=ROUND_HALF_UP):
    return dec(x).quantize(_quant(n), rounding=mode)


BUILTINS = {
    "round": lambda x, n=0: _round(x, n),
    "floor": lambda x, n=0: _round(x, n, ROUND_FLOOR),
    "ceil": lambda x, n=0: _round(x, n, ROUND_CEILING),
    "min": lambda *a: min(dec(x) for x in a),
    "max": lambda *a: max(dec(x) for x in a),
    "abs": lambda x: abs(dec(x)),
}


class _Compiled:
    def __init__(self, text, tree):
        self.text = text
        self.tree = tree

    def __repr__(self):
        return f"<formula {self.text}>"

    def eval(self, env, functions):
        return _Eval(self.text, env, functions).run(self.tree.body)


class _Eval:
    def __init__(self, text, env, functions):
        self.text = text
        self.env = env
        self.functions = functions

    def fail(self, node, message):
        raise FormulaError(message, column=getattr(node, "col_offset", None))

    def run(self, node):
        t = type(node)
        if t is ast.Constant:
            v = node.value
            if isinstance(v, float):
                return Decimal(ast.get_source_segment(self.text, node) or repr(v))
            if isinstance(v, int) and not isinstance(v, bool):
                return Decimal(v)
            return v
        if t is ast.Name or t is ast.Attribute:
            name = node.id if t is ast.Name else _path(node)
            if name in ("True", "False", "None"):
                return {"True": True, "False": False, "None": None}[name]
            return self.env.get(name)
        if t is ast.BinOp:
            if isinstance(node.op, ast.Add):
                la, rb = self.run(node.left), self.run(node.right)
                if isinstance(la, str) or isinstance(rb, str):
                    if la is None or rb is None:
                        self.fail(node, f"valor ausente: {ast.get_source_segment(self.text, node)}")
                    if not (isinstance(la, str) and isinstance(rb, str)):
                        self.fail(node, "só se junta texto com texto")
                    return la + rb
            a, b = self.num(node.left), self.num(node.right)
            op = type(node.op)
            if op is ast.Add:
                return a + b
            if op is ast.Sub:
                return a - b
            if op is ast.Mult:
                return a * b
            if b == 0:
                self.fail(node, "divisão por zero")
            return a / b
        if t is ast.UnaryOp:
            if isinstance(node.op, ast.Not):
                return not self.run(node.operand)
            v = self.num(node.operand)
            return -v if isinstance(node.op, ast.USub) else v
        if t is ast.BoolOp:
            if isinstance(node.op, ast.And):
                v = True
                for x in node.values:
                    v = self.run(x)
                    if not v:
                        return v
                return v
            v = False
            for x in node.values:
                v = self.run(x)
                if v:
                    return v
            return v
        if t is ast.Compare:
            left = self.run(node.left)
            for op, c in zip(node.ops, node.comparators):
                right = self.run(c)
                if not self.compare(node, op, left, right):
                    return False
                left = right
            return True
        if t is ast.IfExp:
            return self.run(node.body) if self.run(node.test) else self.run(node.orelse)
        if t in (ast.Tuple, ast.List):
            return [self.run(e) for e in node.elts]
        if t is ast.Call:
            name = node.func.id
            args = [node.args[0].value] if name == "has" else [self.run(a) for a in node.args]
            if name == "has":
                v = self.env.get(args[0])
                return v is not None and v != ""
            f = BUILTINS.get(name) or self.functions.get(name)
            if f is None:
                self.fail(node, f"função indisponível aqui: {name}")
            try:
                return f(*args)
            except FormulaError as e:
                if e.column is None:
                    e.column = node.col_offset
                raise
        self.fail(node, "construção não permitida")

    def num(self, node):
        v = self.run(node)
        if v is None:
            self.fail(node, f"valor ausente: {ast.get_source_segment(self.text, node)}")
        try:
            return dec(v)
        except FormulaError:
            self.fail(node, f"valor não numérico: {ast.get_source_segment(self.text, node)}")

    @staticmethod
    def _norm(v):
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return dec(v)
        return v

    def compare(self, node, op, a, b):
        a, b = self._norm(a), self._norm(b)
        if isinstance(op, (ast.In, ast.NotIn)):
            if not isinstance(b, list):
                self.fail(node, "use 'in' com uma lista: x in ('a', 'b')")
            r = a in [self._norm(x) for x in b]
            return r if isinstance(op, ast.In) else not r
        if isinstance(op, ast.Eq):
            return a == b
        if isinstance(op, ast.NotEq):
            return a != b
        if a is None or b is None:
            self.fail(node, "comparação com valor ausente")
        try:
            if isinstance(op, ast.Lt):
                return a < b
            if isinstance(op, ast.LtE):
                return a <= b
            if isinstance(op, ast.Gt):
                return a > b
            return a >= b
        except TypeError:
            self.fail(node, "comparação entre tipos diferentes")


def evaluate(compiled, env, functions):
    """Evaluates [(name, compiled)] in order; each result becomes visible to the next ones. Returns {name: value}."""
    out = {}
    scope = dict(env)
    for name, c in compiled:
        try:
            v = c.eval(scope, functions)
        except FormulaError as e:
            e.formula = name
            raise
        except (InvalidOperation, ArithmeticError) as e:
            raise FormulaError(f"cálculo inválido ({type(e).__name__})", formula=name) from None
        out[name] = v
        scope[name] = v
    return out
