# ana:description Link de download de um documento para o cliente ou fornecedor sem conta no portal (validade, limite, senha)
# ana:command link_doc
"""Spec 037 (RF-037-05). The document's PDF is published in the partner's folder and gets a
link with expiry, download limit and optional password. The core refuses links to anything that
is not in a folder for partners: internal documents never leave."""

from ana_lib.docs import pdfs

PARAMS = {
    "kind": {"type": "str", "required": True, "label": "documento", "order": 1,
             "choices": [["order", "Pedido de venda"], ["bill", "Fatura"], ["shipment", "Entrega"], ["service_order", "Atendimento (OS)"],
                         ["receipt", "Recibo (título pago)"], ["statement", "Extrato do cliente"], ["purchase_order", "Ordem de compra"]]},
    "key": {"type": "str", "required": True, "label": "número (extrato: cliente)", "order": 2},
    "hours": {"type": "int", "default": 72, "label": "vale por (horas, até 720)", "order": 3},
    "max_downloads": {"type": "int", "default": 5, "label": "downloads permitidos", "order": 4},
    "password": {"type": "str", "label": "senha (opcional, 4+ caracteres)", "order": 5},
}


def main(kind, key, hours=72, max_downloads=5, password=None):
    party, name, data = pdfs.build(kind, key)
    file = pdfs.find(kind, party, name) or ana.files.publish(kind, party, name, data, comment=f"{pdfs.LABEL[kind]} {key}")["file"]
    link = ana.files.link(file, hours=max(1, min(int(hours or 72), 720)), max_downloads=max_downloads or None, password=password)
    url = (ana.context.public_url.rstrip("/") + link["url"]) if ana.context.public_url else link["url"]
    who = ana.sql_one("SELECT name, email FROM base.party WHERE id = $1", party)
    ana.metrics([{"label": "Documento", "value": name}, {"label": "Vale por", "value": f"{hours} h"},
                 {"label": "Downloads", "value": max_downloads or "sem limite"},
                 {"label": "Senha", "value": "sim" if password else "não"}], title=f"Link para {who['name']}")
    ana.table([{"endereço para enviar": url}], title="Copie e envie ao destinatário" + (f" ({who['email']})" if who["email"] else ""))
    ana.log(f"link de download criado para {name} ({who['name']})")
    return {"url": url, "file": file, "name": name, "link": link["id"]}
