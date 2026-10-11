# ana:description PDF da fatura (pedido ou OS): abre o PDF guardado na pasta do cliente, gerando se preciso
# ana:portal yes
"""Spec 035 (follow-up). Returns {"_download": {"file"}}: the screen opens the PDF. Internal
users generate it when missing (invoices made before the PDFs existed) or on request; a
portal account opens the PDFs of its own company only."""

from ana_lib.finance import invoice_pdf

PARAMS = {
    "bill": {"type": "int", "required": True, "label": "título"},
    "regenerate": {"type": "bool", "default": False, "label": "gerar de novo"},
}


def main(bill, regenerate=False):
    b = ana.sql_one("SELECT id, party_id, document FROM finance.bill WHERE id = $1 AND kind = 'receivable'", bill)
    if not b or (ana.context.party and int(b["party_id"]) != int(ana.context.party)):
        raise ana.Error("BILL_NOT_FOUND", f"título {bill} não encontrado")
    file = None if regenerate else invoice_pdf.find(b["party_id"], b["document"])
    if file is None:
        if ana.context.party:
            raise ana.Error("PDF_NOT_AVAILABLE", "o PDF desta fatura ainda não foi gerado: fale com o nosso financeiro")
        file = invoice_pdf.store(b["document"])
        if file is None:
            raise ana.Error("PDF_NOT_AVAILABLE", "não foi possível guardar o PDF no repositório de arquivos")
    return {"bill": b["id"], "file": file, "name": invoice_pdf.file_name(b["document"]), "_download": {"file": file}}
