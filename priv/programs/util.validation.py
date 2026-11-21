# ana:description Validações de negócio reutilizáveis
# ana:kind library
"""Common validations. Failures are ana.Error (they roll back the execution)."""

import re
from decimal import Decimal, InvalidOperation

import ana


def require(condition, code, message):
    if not condition:
        raise ana.Error(code, message)


def decimal(value, field):
    """Decimal from a number or typed text; Brazilian notation ("1.234,56", "4,79") accepted."""
    try:
        if isinstance(value, (int, float, Decimal)) and not isinstance(value, bool):
            return Decimal(str(value))
        s = str(value).strip()
        if "," in s:
            s = s.replace(".", "").replace(",", ".")
        return Decimal(s)
    except (InvalidOperation, ValueError):
        raise ana.Error("INVALID_VALUE", f"{field} não é um número") from None


def positive_decimal(value, field):
    d = decimal(value, field)
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


def coordinates(latitude, longitude):
    """Spec 032: both or none, inside the globe; returns (lat, lon) as Decimal or (None, None)."""
    if latitude in (None, "") and longitude in (None, ""):
        return None, None
    require(latitude not in (None, "") and longitude not in (None, ""), "INVALID_COORDINATES",
            "informe latitude e longitude juntas")
    lat, lon = decimal(latitude, "latitude"), decimal(longitude, "longitude")
    require(-90 <= lat <= 90, "INVALID_COORDINATES", f"latitude fora de -90..90: {lat}")
    require(-180 <= lon <= 180, "INVALID_COORDINATES", f"longitude fora de -180..180: {lon}")
    return round(lat, 6), round(lon, 6)
