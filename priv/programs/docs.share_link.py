# ana:description Link de download de um documento para o cliente ou fornecedor sem conta no portal (validade, limite, senha)
# ana:command link_doc
# ana:category Documentos e arquivos/Documentos
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
    # T-037-06b: the link goes by e-mail (spec 044) instead of copy and paste.
    "send": {"type": "bool", "default": False, "label": "enviar por e-mail", "order": 6},
    "to": {"type": "str", "label": "para (vazio = e-mail do cadastro; vários separados por vírgula)", "order": 7},
    "note": {"type": "str", "label": "mensagem (opcional)", "order": 8},
}

EMAIL_HTML = ("<p>Olá, $name.</p><p>$company enviou $document.</p><p>$note</p>"
              "<p><a href=\"$url\">Baixar o documento</a></p>"
              "<p style=\"color:#666\">O link vale até $until e permite $downloads download(s).$password</p>")


def main(kind, key, hours=72, max_downloads=5, password=None, send=False, to=None, note=None):
    party, name, data = pdfs.build(kind, key)
    file = pdfs.find(kind, party, name) or ana.files.publish(kind, party, name, data, comment=f"{pdfs.LABEL[kind]} {key}")["file"]
    link = ana.files.link(file, hours=max(1, min(int(hours or 72), 720)), max_downloads=max_downloads or None, password=password)
    url = (ana.context.public_url.rstrip("/") + link["url"]) if ana.context.public_url else link["url"]
    who = ana.sql_one("SELECT name, email FROM base.party WHERE id = $1", party)
    ana.metrics([{"label": "Documento", "value": name}, {"label": "Vale por", "value": f"{hours} h"},
                 {"label": "Downloads", "value": max_downloads or "sem limite"},
                 {"label": "Senha", "value": "sim" if password else "não"}], title=f"Link para {who['name']}")
    email = None
    if send:
        email = mail(kind, who, name, url, hours, max_downloads, password, to, note)
        ana.table([{"enviado para": ", ".join(email["to"]), "endereço": url}], title="Link enviado por e-mail")
        ana.log(f"link de download de {name} enviado por e-mail a {', '.join(email['to'])}")
    else:
        ana.table([{"endereço para enviar": url}], title="Copie e envie ao destinatário" + (f" ({who['email']})" if who["email"] else ""))
        ana.log(f"link de download criado para {name} ({who['name']})")
    return {"url": url, "file": file, "name": name, "link": link["id"], "email": email}


def mail(kind, who, name, url, hours, max_downloads, password, to, note):
    """The link (never the password) to the partner's e-mail, or to the addresses given."""
    rcpt = [a.strip() for a in (to or "").replace(";", ",").split(",") if a.strip()] or ([who["email"]] if who["email"] else [])
    if not rcpt:
        raise ana.Error("NO_RECIPIENT", f"{who['name']} não tem e-mail no cadastro: informe o destinatário")
    company = ana.sql_value("SELECT COALESCE(display_name, legal_name) FROM base.company ORDER BY id LIMIT 1") or "A empresa"
    until = ana.sql_value("SELECT to_char(now() + make_interval(hours => $1), 'DD/MM/YYYY HH24:MI')", int(hours or 72))
    document = f"{pdfs.LABEL[kind].lower()} {name}"
    secret = " A senha para abrir será informada por outro meio." if password else ""
    text = (f"Olá, {who['name']}.\n\n{company} enviou {document}.\n" + (f"\n{note}\n" if note else "") +
            f"\nBaixe em: {url}\n\nO link vale até {until} e permite {max_downloads or 'quantos'} download(s).{secret}\n")
    mid = ana.send_email(rcpt, f"{company}: {document}", text=text, html_template=EMAIL_HTML,
                         data={"name": who["name"], "company": company, "document": document, "url": url, "until": until,
                               "downloads": max_downloads or "quantos", "password": secret,
                               "note": note or ""})
    return {"id": mid, "to": rcpt}
