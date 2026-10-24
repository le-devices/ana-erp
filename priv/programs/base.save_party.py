# ana:description Cria ou atualiza cliente/fornecedor
# ana:exposed yes
# ana:command party
# ana:category Cadastros/Clientes, fornecedores e itens
"""Creates a party (no `id`) or updates an existing one (with `id`)."""

from ana_lib.util import validation as v

PARAMS = {
    "id": {"type": "int", "label": "cadastro (id; vazio = novo)"},
    "kind": {"type": "str", "default": "customer", "label": "tipo", "choices": [["customer", "Cliente"], ["supplier", "Fornecedor"], ["both", "Cliente e fornecedor"]]},
    "name": {"type": "str", "required": True, "label": "nome"},
    "tax_id": {"type": "str", "label": "CNPJ/CPF"},
    "email": {"type": "str", "label": "e-mail"},
    "city": {"type": "str", "label": "cidade"},
    "state": {"type": "str", "label": "UF"},
    "address": {"type": "str", "label": "endereço (rua, número, bairro)"},
    "latitude": {"type": "decimal", "label": "latitude (ex.: -23,5505)"},
    "longitude": {"type": "decimal", "label": "longitude (ex.: -46,6333)"},
    "salesperson": {"type": "str", "label": "vendedor (login) — dono da carteira"},
}


def main(name, kind="customer", id=None, tax_id=None, email=None, city=None, state=None, address=None, latitude=None,
         longitude=None, salesperson=None):
    v.require(kind in ("customer", "supplier", "both"), "INVALID_KIND", f"tipo inválido: {kind}")
    v.require(2 <= len(name.strip()) <= 200, "INVALID_NAME", "nome deve ter de 2 a 200 caracteres")
    lat, lon = v.coordinates(latitude, longitude)       # spec 032
    salesperson = (salesperson or "").strip() or None
    # Spec 009 (D10): the salesperson owns the customer's portfolio; it must be an active person.
    v.require(salesperson is None or ana.sql_value("SELECT bpm.user_exists($1)", salesperson),
              "USER_NOT_FOUND", f"vendedor {salesperson} não é um usuário ativo")
    data = (kind, name.strip(), tax_id, v.email(email), city, v.state(state), (address or "").strip() or None, lat, lon, salesperson)
    if id is None:
        new_id = ana.sql_value(
            "INSERT INTO base.party (kind, name, tax_id, email, city, state, address, latitude, longitude, salesperson) "
            "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING id", *data)
        ana.log(f"parte {new_id} criada")
        return {"id": new_id, "created": True}
    n = ana.sql_exec(
        "UPDATE base.party SET kind=$1, name=$2, tax_id=$3, email=$4, city=$5, state=$6, address=$7, latitude=$8, "
        "longitude=$9, salesperson = COALESCE($10, salesperson) WHERE id = $11",
        *data, id)
    v.require(n == 1, "PARTY_NOT_FOUND", f"parte {id} não existe")
    return {"id": id, "created": False}
