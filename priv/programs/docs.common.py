# ana:description Ligações para documentos: o "abrir" das linhas e a leitura de "ORD-12", "OS-5"…
# ana:kind library
"""Spec 035. link(kind, key) is what a table row puts in `_open`; of_text() turns the document
text used on bills and entries into the document it came from."""

import re

KINDS = {"order": "Pedido de venda", "bill": "Título", "service_order": "Ordem de serviço", "purchase_request": "Solicitação de compra",
         "purchase_order": "Ordem de compra", "work_order": "Ordem de produção", "shipment": "Expedição", "transfer": "Transferência",
         "entry": "Lançamento contábil", "project_invoice": "Fatura de projeto", "statement_line": "Linha do extrato"}
# Document texts as the processes write them (installments "/n", residuals "/R", cancellations "-CANC", reversals
# "-REV", notes and returns that name the purchase order) → the document they come from (spec 042, M-02).
_TEXT = [(re.compile(r"^ORD-(\d+)(?:/\d+)?(?:/R)*(?:-CANC)?$"), "order"), (re.compile(r"^OS-(\d+)(?:/\d+)?(?:/R)*(?:-CANC)?$"), "service_order"),
         (re.compile(r"^OC-(\d+)(?:/\d+)*(?:/R)*$"), "purchase_order"), (re.compile(r"^DEVF-OC-(\d+)-\d+$"), "purchase_order"),
         (re.compile(r"^NF-.*-OC-(\d+)$"), "purchase_order"),
         (re.compile(r"^OP-(\d+)(?:/\d+)?$"), "work_order"), (re.compile(r"^INV-(\d+)(?:/R)*(?:-REV)?$"), "project_invoice"),
         (re.compile(r"^(?:CRED-)?EXT-(\d+)(?:/R)*(?:-REV)?$"), "statement_line"),
         (re.compile(r"^TR-(\d+)$"), "transfer"), (re.compile(r"^EXP-(\d+)(?:-VOLTA)?$"), "shipment")]
_OFFSET = re.compile(r"^COMP-(\d+)-(\d+)$")


def link(kind, key):
    return {"program": "docs.view", "params": {"kind": kind, "key": str(key)}}


def offset_bills(document):
    """(credit bill, debit bill) of a compensation entry "COMP-12-34"; None otherwise."""
    m = _OFFSET.match(str(document or "").strip().upper())
    return (int(m.group(1)), int(m.group(2))) if m else None


def of_text(document):
    """("order", "12") for "ORD-12" or "ORD-12/2"; None when the text is not a known document."""
    for rx, kind in _TEXT:
        m = rx.match(str(document or "").strip().upper())
        if m:
            return kind, m.group(1)
    return None
