# ana:description Condição de pagamento: forma, parcelas e prazos, entrada, desconto/acréscimo e taxa
# ana:exposed yes
# ana:command condicao
"""RF-031-01. installments: "30/60/90" (equal parts) or [{"days": 30, "pct": 50}, …]; the
database checks that installments + down payment add up to 100 %."""

from decimal import Decimal, ROUND_HALF_UP

PARAMS = {
    "code": {"type": "str", "required": True, "label": "código", "order": 1},
    "name": {"type": "str", "required": True, "label": "nome", "order": 2},
    "method": {"type": "str", "required": True, "label": "forma", "order": 3,
               "choices": [["pix", "PIX"], ["boleto", "Boleto"], ["credit_card", "Cartão de crédito"], ["debit_card", "Cartão de débito"],
                           ["direct_credit", "Crédito direto"], ["cash", "Dinheiro"], ["transfer", "Transferência"]]},
    "installments": {"type": "str", "default": "0", "label": "prazos em dias (ex.: 30/60/90; 0 = à vista)", "order": 4},
    "down_payment_pct": {"type": "decimal", "default": 0, "label": "entrada (%)", "order": 5},
    "adjust_pct": {"type": "decimal", "default": 0, "label": "desconto (−) ou acréscimo (+) %", "order": 6},
    "fee_pct": {"type": "decimal", "default": 0, "label": "taxa da operadora (%)", "order": 7},
    "min_amount": {"type": "decimal", "default": 0, "label": "valor mínimo", "order": 8},
    "connector": {"type": "str", "label": "conector de cobrança (PIX/boleto/cartão)", "order": 9},
    "active": {"type": "bool", "default": True, "label": "ativa", "order": 10},
    "schedule": {"type": "list", "label": "parcelas detalhadas (integração)", "order": 11},
}


def parse(text, down):
    days = [int(x) for x in str(text).replace(",", "/").replace(" ", "").split("/") if x != ""]
    if not days or any(d < 0 for d in days):
        raise ana.Error("INVALID_INSTALLMENTS", "informe os prazos em dias, ex.: 30/60/90")
    rest = Decimal(100) - Decimal(down)
    each = (rest / len(days)).quantize(Decimal("0.01"), ROUND_HALF_UP)
    pcts = [each] * (len(days) - 1) + [rest - each * (len(days) - 1)]
    return [{"days": d, "pct": str(p)} for d, p in zip(days, pcts)]


def main(code, name, method, installments="0", down_payment_pct=0, adjust_pct=0, fee_pct=0, min_amount=0, connector=None,
         active=True, schedule=None):
    rows = schedule or parse(installments, down_payment_pct)
    import json
    ana.sql_exec("INSERT INTO finance.payment_term (code, name, method, installments, down_payment_pct, adjust_pct, fee_pct, "
                 "  min_amount, connector, active) VALUES ($1, $2, $3, $4::text::jsonb, $5, $6, $7, $8, $9, $10) "
                 "ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, method = EXCLUDED.method, installments = EXCLUDED.installments, "
                 "  down_payment_pct = EXCLUDED.down_payment_pct, adjust_pct = EXCLUDED.adjust_pct, fee_pct = EXCLUDED.fee_pct, "
                 "  min_amount = EXCLUDED.min_amount, connector = EXCLUDED.connector, active = EXCLUDED.active",
                 code.strip().upper(), name, method, json.dumps(rows), down_payment_pct, adjust_pct, fee_pct, min_amount, connector, active)
    return {"code": code.strip().upper(), "installments": len(rows)}
