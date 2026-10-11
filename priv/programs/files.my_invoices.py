# ana:description Minhas faturas: títulos e PDFs do cliente da conta do portal
# ana:portal yes
# ana:command faturas
"""Spec 016 (H3, CA-016-05). For an external portal account: its receivable bills and the
invoice PDFs shared in its folder. Internal users choose the customer."""

from ana_lib.docs.common import link as doc_link
from ana_lib.util.format import money

PARAMS = {"customer": {"type": "int", "label": "cliente (só para usuários internos)"}}


def main(customer=None):
    party = ana.context.party or customer
    if not party:
        raise ana.Error("INVALID_PARAMETER", "informe o cliente")
    if ana.context.party and customer and int(customer) != int(ana.context.party):
        raise ana.Error("FORBIDDEN", "a conta do portal só vê as próprias faturas")
    bills = ana.sql("SELECT id, document, issue_date, due_date, amount, status FROM finance.bill "
                    "WHERE party_id = $1 AND kind = 'receivable' ORDER BY issue_date DESC, id DESC LIMIT 200", party)
    labels = {"open": "em aberto", "settled": "paga", "cancelled": "cancelada"}
    # Spec 035 (CA-035-01): each invoice opens with its installments, charges and origin.
    ana.table([{"documento": b["document"], "_open": doc_link("bill", b["id"]), "emissão": b["issue_date"], "vencimento": b["due_date"],
                "valor": money(b["amount"]), "situação": labels.get(b["status"], b["status"])} for b in bills],
              title="Faturas")
    try:
        folder = ana.files.folder(entity=("party", int(party)), subfolder="Faturas", create=False)
        pdfs = ana.files.list(folder)["files"]
    except ana.Error:
        pdfs = []
    if pdfs:
        ana.table([{"arquivo": f["name"], "atualizado": f["updated_at"]} for f in pdfs],
                  title="PDFs (baixe em Arquivos)")
    return {"bills": len(bills), "pdfs": [f["name"] for f in pdfs]}
