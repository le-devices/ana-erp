# ana:description PDF de documento para cliente ou fornecedor (pedido, fatura, entrega, atendimento, recibo, extrato, ordem de compra)
# ana:portal yes
"""Spec 037. Internal users generate and publish the PDF in the partner's folder for that kind
and open it; a portal account opens only PDFs already published for its own company. Internal
documents (entries, production orders, transfers…) are refused: INTERNAL_DOCUMENT."""

from ana_lib.docs import pdfs

PARAMS = {
    "kind": {"type": "str", "required": True, "label": "documento", "order": 1,
             "choices": [["order", "Pedido de venda"], ["bill", "Fatura"], ["shipment", "Entrega"], ["service_order", "Atendimento (OS)"],
                         ["receipt", "Recibo (título pago)"], ["statement", "Extrato do cliente"], ["purchase_order", "Ordem de compra"]]},
    "key": {"type": "str", "required": True, "label": "número (extrato: cliente)", "order": 2},
    "start": {"type": "date", "label": "extrato: de", "order": 3},
    "end": {"type": "date", "label": "extrato: até", "order": 4},
    "regenerate": {"type": "bool", "default": False, "label": "gerar de novo", "order": 5},
}


def main(kind, key, start=None, end=None, regenerate=False):
    party, name, data = pdfs.build(kind, key, start=start, end=end)
    if ana.context.party and int(party) != int(ana.context.party):
        raise ana.Error("DOCUMENT_NOT_FOUND", "documento não encontrado")
    file = None if regenerate else pdfs.find(kind, party, name)
    if file is None:
        if ana.context.party:
            raise ana.Error("PDF_NOT_AVAILABLE", "este documento ainda não foi disponibilizado: fale com a empresa")
        file = ana.files.publish(kind, party, name, data, comment=f"{pdfs.LABEL[kind]} {key}")["file"]
    return {"kind": kind, "key": str(key), "file": file, "name": name, "_download": {"file": file}}
