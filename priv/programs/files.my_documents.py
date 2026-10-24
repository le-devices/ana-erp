# ana:description Meus documentos: pedidos, faturas, entregas, atendimentos, recibos e extratos da empresa
# ana:portal yes
# ana:command documentos
# ana:category Documentos e arquivos/Portal
"""Spec 037 (RF-037-04). Lists only the folders made for the partner (published documents);
the partner's internal folder never appears. Internal users choose the customer or supplier."""

from ana_lib.docs import pdfs

PARAMS = {"party": {"type": "int", "label": "cliente ou fornecedor (só para usuários internos)",
                    "lookup": {"program": "sales.lookup", "params": {"kind": "customers"}}}}
KIND_OF = {v: k for k, v in pdfs.SUBFOLDER.items()}


def main(party=None):
    party = ana.context.party or party
    if not party:
        raise ana.Error("INVALID_PARAMETER", "informe o cliente ou fornecedor")
    if ana.context.party and int(party) != int(ana.context.party):
        raise ana.Error("FORBIDDEN", "a conta do portal só vê os documentos da própria empresa")
    rows = []
    for sub in dict.fromkeys(pdfs.SUBFOLDER.values()):
        try:
            # ana:lint-ok sql_in_loop — one folder per kind of document (a handful)
            folder = ana.files.folder(entity=("party", int(party)), subfolder=sub, create=False)
            files = ana.files.list(folder)["files"]
        except ana.Error:
            continue
        for f in files:
            rows.append({"tipo": pdfs.LABEL[KIND_OF[sub]], "documento": f["name"], "atualizado": f["updated_at"], "versão": f["version"],
                         "_actions": [{"label": "Baixar", "program": "files.download", "params": {"file": f["id"]}, "download": True}]})
    rows.sort(key=lambda r: str(r["atualizado"]), reverse=True)
    ana.table(rows, title="Documentos")
    return {"party": int(party), "documents": len(rows)}
