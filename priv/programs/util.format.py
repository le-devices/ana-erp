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


def compact(value):
    """compact(Decimal('82.000')) -> '82'; compact(Decimal('1234.50')) -> '1.234,5' (no trailing zeros)."""
    v = Decimal(str(value)).normalize()
    sign = "-" if v < 0 else ""
    integer, _, frac = f"{abs(v):f}".partition(".")
    return f"{sign}{_thousands(int(integer))}" + (f",{frac}" if frac else "")


def date_br(d):
    return d.strftime("%d/%m/%Y") if d else ""


# Situations as people say them (spec 042, B-05): messages never show the internal code ("está INVOICED").
STATUS = {"OPEN": "em aberto", "INVOICED": "faturado", "CANCELLED": "cancelado", "open": "em aberto", "settled": "baixado",
          "cancelled": "cancelado", "matched": "conciliada", "proposal": "em proposta", "active": "ativo", "suspended": "suspenso",
          "closed": "encerrado", "done": "concluída", "invoiced": "faturada", "scheduled": "agendada", "en_route": "a caminho",
          "in_progress": "em andamento", "pending": "pendente", "approved": "aprovado", "rejected": "recusado", "paid": "paga",
          "issued": "emitida", "failed": "com falha", "requested": "pedida", "draft": "em rascunho", "submitted": "enviada",
          "implemented": "implementada", "completed": "concluído", "planned": "planejado", "released": "liberado"}


def status_text(code):
    return STATUS.get(code, str(code))
