# ana:description Busca da paleta de comandos: documentos pelo número, clientes e fornecedores pelo CNPJ/CPF ou nome, itens
# ana:kind program
# ana:menu no
"""Spec 050 (D4, RF-050-04, CA-050-02). What Ctrl+K finds besides the routines and the screen's actions, as the user
who types (role, groups, license, data scope): documents by number ("123", "ORD-12", "OC-5"…) — only for who may open
documents —, customers and suppliers by CNPJ/CPF (with or without punctuation) or name, and items by code or
description — only the records the user may see. Each answer says where it opens ({"hash": "#/…"})."""

import re

from ana_lib.docs import common as docs
from ana_lib.master import core
from ana_lib.util.format import status_text

PARAMS = {"q": {"type": "str", "required": True, "label": "buscar"}}

# Documents found by their number (kind → table, label). The number is the document's own key on docs.view.
NUMBERED = [("order", "sales.sales_order", "Pedido de venda"), ("service_order", "field.service_order", "Ordem de serviço"),
            ("purchase_request", "supply.purchase_request", "Solicitação de compra"),
            ("purchase_order", "supply.purchase_order", "Ordem de compra"), ("work_order", "production.work_order", "Ordem de produção"),
            ("shipment", "logistics.shipment", "Expedição"), ("project_invoice", "projects.invoice", "Fatura de projeto")]
PREFIX = {"PV": "order", "PED": "order", "SC": "purchase_request", "EXP": "shipment", "INV": "project_invoice"}
EACH = 5
TAX_ID = re.compile(r"(?=(?:.*\d){2})[0-9A-Za-z]{2}\.?[0-9A-Za-z]{3}\.?[0-9A-Za-z]{3}/?[0-9A-Za-z]{4}-?\d{2}|\d{3}\.?\d{3}\.?\d{3}-?\d{2}")


def quote(text):
    """Percent-encodes what is not a plain letter, digit or "-._~" (a key in a screen address)."""
    return "".join(ch if re.fullmatch(r"[A-Za-z0-9._~-]", ch) else "".join(f"%{b:02X}" for b in ch.encode()) for ch in str(text))


def doc_hash(kind, key):
    return f"#/ops/docs/docs.view?kind={kind}&key={quote(str(key))}"


def documents(q):
    t = q.strip().upper()
    known = docs.of_text(t)
    m = re.match(r"^([A-Z]{2,3})[- ]?(\d+)$", t)
    if known:
        kinds, n = [known[0]], int(known[1])
    elif m and m.group(1) in PREFIX:
        kinds, n = [PREFIX[m.group(1)]], int(m.group(2))
    elif re.fullmatch(r"\d{1,9}", t):
        kinds, n = [k for k, _, _ in NUMBERED], int(t)
    else:
        return []
    out = []
    for kind, table, label in NUMBERED:
        if kind not in kinds:
            continue
        # ana:lint-ok sql_in_loop — one indexed lookup per kind of document (at most seven)
        # ana:lint-ok dynamic_sql — the table comes from the fixed list above; the number goes as $1
        row = ana.sql_one(f"SELECT number, status FROM {table} WHERE number = $1", n)
        if row:
            out.append({"group": "Documentos", "label": f"{label} {row['number']}", "detail": status_text(row["status"]) if row["status"] else "",
                        "hash": doc_hash(kind, row["number"])})
    return out


def records(q):
    out = []
    party = core.entity("party")
    # The shape of a CPF or CNPJ (numeric or alphanumeric, with or without punctuation, no spaces) and valid check
    # digits: searched by the document; found nothing, the text is still searched as a name.
    if core.can(party, "view") and TAX_ID.fullmatch(q.strip()) and ana.sql_value("SELECT base.valid_tax_id($1)", q.strip()):
        for r in ana.sql("SELECT id, name, tax_id, kind FROM base.party WHERE tax_id = base.format_tax_id($1)", q.strip()):
            out.append({"group": "Cadastros", "label": r["name"], "detail": f"{r['tax_id']} · {KIND.get(r['kind'], '')}",
                        "hash": f"#/master/party/{r['id']}"})
        if out:
            return out
    if len(q.strip()) < 3:
        return out
    for name, label in (("party", "Cliente ou fornecedor"), ("product", "Item")):
        d = core.entity(name)
        if not core.can(d, "view"):
            continue
        for r in core.search(name, q, None, "true", 0, EACH)["rows"]:
            out.append({"group": "Cadastros", "label": r["title"], "detail": label,
                        "hash": f"#/master/{name}/{quote(str(r['key']))}"})
    return out


KIND = {"customer": "cliente", "supplier": "fornecedor", "both": "cliente e fornecedor"}


def main(q):
    q = str(q or "").strip()[:100]
    if not q:
        return []
    found = records(q)
    if ana.can_run("docs.view"):
        found = documents(q) + found
    return found
