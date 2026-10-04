# ana:description Formatação de valores: moeda, quantidade e datas
# ana:kind library
"""Formatting library. Usage: from ana_lib.util.format import money"""

from decimal import Decimal, ROUND_HALF_EVEN


def _thousands(integer):
    return f"{integer:,}".replace(",", ".")


def money(value, symbol="R$"):
    """money(Decimal('1234.5')) -> 'R$ 1.234,50'"""
    v = Decimal(str(value)).quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)
    sign = "-" if v < 0 else ""
    integer, _, frac = f"{abs(v):.2f}".partition(".")
    return f"{sign}{symbol} {_thousands(int(integer))},{frac}"


def quantity(value, places=3):
    v = Decimal(str(value)).quantize(Decimal(1).scaleb(-places))
    integer, _, frac = f"{abs(v):.{places}f}".partition(".")
    sign = "-" if v < 0 else ""
    return f"{sign}{_thousands(int(integer))},{frac}" if places else f"{sign}{_thousands(int(integer))}"


def date_br(d):
    return d.strftime("%d/%m/%Y") if d else ""
