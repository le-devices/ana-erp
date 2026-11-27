# ana:description Câmbio: cotação de uma moeda numa data (valores da empresa) e conversão para reais
# ana:kind library
"""Spec 069 (T-069-01, RF-069-07). The rate of a currency on a date is the company value
"financeiro.cotacao_<moeda>" in force on that date (spec 065): reais for one unit. The real is 1. A currency without
a rate in force is refused with what to do — never converted at 1 by accident."""

from decimal import Decimal, ROUND_HALF_UP

import ana

CENT = Decimal("0.01")
UNIT = Decimal("0.0001")
NAMES = {"BRL": "real", "USD": "dólar", "EUR": "euro"}


def rate(currency, at=None):
    """Reais for one unit of `currency` on `at` (a date; today when None)."""
    cur = (currency or "BRL").strip().upper()
    if cur == "BRL":
        return Decimal(1)
    try:
        r = ana.value(f"financeiro.cotacao_{cur.lower()}", at=at)
    except ana.Error as e:
        if e.code != "VALUE_NOT_FOUND":
            raise
        r = None
    if r is None or Decimal(str(r)) <= 0:
        when = f" em {at}" if at else ""
        raise ana.Error("CURRENCY_RATE_MISSING",
                        f"sem cotação do {NAMES.get(cur, cur)}{when}: informe-a em Administração → Valores da empresa "
                        f"(financeiro.cotacao_{cur.lower()})")
    return Decimal(str(r))


def to_brl(amount, currency, at=None, places=CENT):
    """`amount` in `currency` converted to reais at the rate of `at`, rounded to `places` (cents by default)."""
    return (Decimal(str(amount)) * rate(currency, at)).quantize(places, rounding=ROUND_HALF_UP)
