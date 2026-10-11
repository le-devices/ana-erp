# ana:description Ligações para documentos: o "abrir" das linhas e a leitura de "ORD-12", "OS-5"…
# ana:kind library
"""Spec 035. link(kind, key) is what a table row puts in `_open`; of_text() turns the document
text used on bills and entries into the document it came from."""

import re

KINDS = {"order": "Pedido de venda", "bill": "Título", "service_order": "Ordem de serviço", "purchase_request": "Solicitação de compra",
         "purchase_order": "Ordem de compra", "work_order": "Ordem de produção", "shipment": "Expedição", "transfer": "Transferência",
         "entry": "Lançamento contábil"}
_TEXT = [(re.compile(r"^ORD-(\d+)(?:/\d+)?$"), "order"), (re.compile(r"^OS-(\d+)$"), "service_order"),
         (re.compile(r"^OC-(\d+)$"), "purchase_order"), (re.compile(r"^OP-(\d+)(?:/\d+)?$"), "work_order"),
         (re.compile(r"^TR-(\d+)$"), "transfer"), (re.compile(r"^EXP-(\d+)(?:-VOLTA)?$"), "shipment")]


def link(kind, key):
    return {"program": "docs.view", "params": {"kind": kind, "key": str(key)}}


def of_text(document):
    """("order", "12") for "ORD-12" or "ORD-12/2"; None when the text is not a known document."""
    for rx, kind in _TEXT:
        m = rx.match(str(document or "").strip().upper())
        if m:
            return kind, m.group(1)
    return None
