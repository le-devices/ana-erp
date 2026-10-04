# ana:description Validações de negócio reutilizáveis
# ana:kind library
"""Common validations. Failures are ana.Error (they roll back the execution)."""

import re
from decimal import Decimal, InvalidOperation

import ana


def require(condition, code, message):
    if not condition:
        raise ana.Error(code, message)


def positive_decimal(value, field):
    try:
        d = Decimal(str(value))
    except (InvalidOperation, ValueError):
        raise ana.Error("INVALID_VALUE", f"{field} não é um número") from None
    require(d > 0, "INVALID_VALUE", f"{field} deve ser positivo")
    return d


def state(value):
    if value is None:
        return None
    v = str(value).strip().upper()
    require(re.fullmatch(r"[A-Z]{2}", v) is not None, "INVALID_STATE", f"UF inválida: {value}")
    return v


def email(value):
    if not value:
        return None
    require(re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", value) is not None,
            "INVALID_EMAIL", f"e-mail inválido: {value}")
    return value.lower()
