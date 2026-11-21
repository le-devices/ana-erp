# ana:description Cria ou atualiza cliente/fornecedor
# ana:exposed yes
# ana:command party
# ana:category Cadastros/Clientes, fornecedores e itens
"""Creates a party (no `id`) or updates an existing one (with `id`)."""

from ana_lib.util import validation as v

_KEEP = object()

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
    # Spec 043 (D4): fiscal data. Left out by the caller = kept as is (older callers never erase them).
    "country": {"type": "str", "label": "país (código de 2 letras; vazio = BR)"},
    "foreign_id": {"type": "str", "label": "identificação estrangeira (só para estrangeiros)"},
    "state_registration": {"type": "str", "label": "inscrição estadual (ou ISENTO)"},
    "icms_taxpayer": {"type": "str", "label": "contribuinte do ICMS",
                      "choices": [["taxpayer", "Contribuinte"], ["exempt", "Isento"], ["non_taxpayer", "Não contribuinte"]]},
    "municipal_registration": {"type": "str", "label": "inscrição municipal"},
    "tax_regime": {"type": "str", "label": "regime tributário",
                   "choices": [["simples", "Simples Nacional"], ["simples_excess", "Simples Nacional — excesso de sublimite"],
                               ["presumed", "Lucro Presumido"], ["real", "Lucro Real"], ["mei", "MEI"],
                               ["public", "Órgão público"], ["nonprofit", "Entidade sem fins lucrativos"]]},
    "final_consumer": {"type": "bool", "label": "consumidor final"},
}
FISCAL = ("country", "foreign_id", "state_registration", "icms_taxpayer", "municipal_registration", "tax_regime",
          "final_consumer")


def main(name, kind="customer", id=None, tax_id=None, email=None, city=None, state=None, address=None, latitude=None,
         longitude=None, salesperson=None, country=_KEEP, foreign_id=_KEEP, state_registration=_KEEP, icms_taxpayer=_KEEP,
         municipal_registration=_KEEP, tax_regime=_KEEP, final_consumer=_KEEP):
    v.require(kind in ("customer", "supplier", "both"), "INVALID_KIND", f"tipo inválido: {kind}")
    v.require(2 <= len(name.strip()) <= 200, "INVALID_NAME", "nome deve ter de 2 a 200 caracteres")
    lat, lon = v.coordinates(latitude, longitude)       # spec 032
    salesperson = (salesperson or "").strip() or None
    # Spec 009 (D10): the salesperson owns the customer's portfolio; it must be an active person.
    v.require(salesperson is None or ana.sql_value("SELECT bpm.user_exists($1)", salesperson),
              "USER_NOT_FOUND", f"vendedor {salesperson} não é um usuário ativo")
    fiscal = {k: val for k, val in zip(FISCAL, (country, foreign_id, state_registration, icms_taxpayer, municipal_registration,
                                                 tax_regime, final_consumer)) if val is not _KEEP}
    for k in ("country", "foreign_id", "state_registration", "icms_taxpayer", "municipal_registration", "tax_regime"):
        if k in fiscal:
            fiscal[k] = (str(fiscal[k]).strip() or None) if fiscal[k] is not None else None
    if "country" in fiscal:
        fiscal["country"] = (fiscal["country"] or "BR").upper()
        v.require(len(fiscal["country"]) == 2 and fiscal["country"].isalpha(), "INVALID_COUNTRY", "país: use o código de 2 letras (BR, US…)")
    v.require(fiscal.get("icms_taxpayer") in (None, "taxpayer", "exempt", "non_taxpayer"), "INVALID_PARAMETER",
              "contribuinte do ICMS: contribuinte, isento ou não contribuinte")
    v.require(fiscal.get("tax_regime") in [None] + [r[0] for r in PARAMS["tax_regime"]["choices"]], "INVALID_PARAMETER",
              "regime tributário inválido")
    # The database checks and formats the document, the registration and their coherence (spec 043, D1).
    cols = ["kind", "name", "tax_id", "email", "city", "state", "address", "latitude", "longitude"] + sorted(fiscal)
    vals = [kind, name.strip(), tax_id, v.email(email), city, v.state(state), (address or "").strip() or None, lat, lon] + \
        [fiscal[c] for c in sorted(fiscal)]
    if id is None:
        new_id = ana.sql_value(
            f"INSERT INTO base.party ({', '.join(cols)}, salesperson) "
            f"VALUES ({', '.join(f'${i + 1}' for i in range(len(cols) + 1))}) RETURNING id", *vals, salesperson)
        ana.log(f"parte {new_id} criada")
        return {"id": new_id, "created": True}
    sets = ", ".join(f"{c} = ${i + 1}" for i, c in enumerate(cols))
    n = ana.sql_exec(f"UPDATE base.party SET {sets}, salesperson = COALESCE(${len(cols) + 1}, salesperson) "
                     f"WHERE id = ${len(cols) + 2}", *vals, salesperson, id)
    v.require(n == 1, "PARTY_NOT_FOUND", f"parte {id} não existe")
    return {"id": id, "created": False}
