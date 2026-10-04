# ana:description Cria ou atualiza cliente/fornecedor
# ana:exposed yes
# ana:command party
"""Creates a party (no `id`) or updates an existing one (with `id`)."""

from ana_lib.util import validation as v

PARAMS = {
    "id": {"type": "int"},
    "kind": {"type": "str", "default": "customer"},
    "name": {"type": "str", "required": True},
    "tax_id": {"type": "str"},
    "email": {"type": "str"},
    "city": {"type": "str"},
    "state": {"type": "str"},
}


def main(name, kind="customer", id=None, tax_id=None, email=None, city=None, state=None):
    v.require(kind in ("customer", "supplier", "both"), "INVALID_KIND", f"tipo inválido: {kind}")
    v.require(2 <= len(name.strip()) <= 200, "INVALID_NAME", "nome deve ter de 2 a 200 caracteres")
    data = (kind, name.strip(), tax_id, v.email(email), city, v.state(state))
    if id is None:
        new_id = ana.sql_value(
            "INSERT INTO base.party (kind, name, tax_id, email, city, state) "
            "VALUES ($1, $2, $3, $4, $5, $6) RETURNING id", *data)
        ana.log(f"parte {new_id} criada")
        return {"id": new_id, "created": True}
    n = ana.sql_exec(
        "UPDATE base.party SET kind=$1, name=$2, tax_id=$3, email=$4, city=$5, state=$6 WHERE id = $7",
        *data, id)
    v.require(n == 1, "PARTY_NOT_FOUND", f"parte {id} não existe")
    return {"id": id, "created": False}
