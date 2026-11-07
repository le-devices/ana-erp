# ana:description Busca razão social, endereço e situação cadastral de um CNPJ por um conector de consulta (opcional)
# ana:exposed yes
# ana:category Cadastros/Clientes, fornecedores e itens
"""Spec 043 (RF-043-05, D6). Works only with an active HTTP connector whose options say
{"purpose": "tax_id_lookup"}; options.path is the address with {cnpj} (default "/{cnpj}") and
options.fields maps our fields to the answer's (dotted paths; a list is joined with ", "). Never
writes: the record sheet fills the empty fields and shows the differences to confirm."""

import re

from ana_lib.util import tax_id as tid

PARAMS = {"tax_id": {"type": "str", "required": True, "label": "CNPJ"}}

# Common public CNPJ services answer with these names; a connector maps its own in options.fields.
DEFAULT_FIELDS = {"name": "razao_social", "address": ["logradouro", "numero", "complemento", "bairro"],
                  "city": "municipio", "state": "uf", "email": "email", "status": "descricao_situacao_cadastral"}
WRITABLE = ("name", "address", "city", "state", "email")


def connector():
    return ana.sql_one("SELECT name, options FROM integration.connector WHERE active AND kind = 'http_api' "
                       "AND options ->> 'purpose' = 'tax_id_lookup' ORDER BY name LIMIT 1")


def pick(data, path):
    if isinstance(path, list):
        parts = [str(pick(data, p) or "").strip() for p in path]
        return ", ".join(p for p in parts if p) or None
    cur = data
    for k in str(path).split("."):
        cur = cur.get(k) if isinstance(cur, dict) else None
    return cur


def main(tax_id):
    doc = tid.check(tax_id, "CNPJ")
    if tid.kind(tax_id) != "company":
        raise ana.Error("INVALID_TAX_ID", "a consulta é só para CNPJ")
    c = connector()
    if not c:
        raise ana.Error("NO_LOOKUP_CONNECTOR", "nenhum conector de consulta de CNPJ configurado (Integrações)")
    opts = c["options"] or {}
    raw = re.sub(r"[^0-9A-Z]", "", doc)
    r = ana.http(c["name"], "GET", str(opts.get("path") or "/{cnpj}").replace("{cnpj}", raw))
    if r.get("status") == 404:
        raise ana.Error("TAX_ID_NOT_FOUND", f"CNPJ {doc} não encontrado no serviço de consulta")
    if not r.ok or not isinstance(r.get("json"), dict):
        raise ana.Error("LOOKUP_FAILED", f"o serviço de consulta respondeu {r.get('status')}: tente mais tarde")
    fields = {**DEFAULT_FIELDS, **(opts.get("fields") or {})}
    found = {k: pick(r["json"], p) for k, p in fields.items()}
    values = {k: (str(v).strip() if v is not None else None) for k, v in found.items() if k in WRITABLE and v not in (None, "")}
    if values.get("state"):
        values["state"] = values["state"].upper()[:2]
    return {"tax_id": doc, "values": values, "status": found.get("status"), "connector": c["name"]}
