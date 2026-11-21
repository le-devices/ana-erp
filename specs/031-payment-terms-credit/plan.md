# 031 — Plano técnico

## Dados (migração `028_payment_terms_credit.sql`)
- `finance.payment_term` (código, nome, forma, `installments` jsonb
  `[{"days", "pct"}]`, entrada %, ajuste % (desconto < 0, acréscimo > 0),
  taxa da operadora %, valor mínimo, conector de cobrança, ativa); gatilho
  valida a soma = 100 (com a entrada).
- `finance.party_payment_term` (condições permitidas por cliente; nenhuma =
  todas as ativas).
- `finance.credit_policy` (id = 1: bloqueio automático, tolerância padrão,
  condição padrão) e `finance.credit_profile` (por cliente: limite,
  tolerância, bloqueio automático, condição padrão).
- `finance.credit_block` (manual: motivo, validade, quem bloqueou/liberou) e
  `finance.credit_release` (liberação pontual de um pedido, usada uma vez).
- `sales.sales_order.payment_term`; `finance.bill.installment`,
  `installments`, `payment_method`, `payment_term`.
- Função `finance.credit_status(cliente, valor_extra)`: bloqueado?, motivo,
  aberto, vencido além da tolerância, maior atraso, limite, disponível.
- Produto traz `AVISTA` e `D30`; a demonstração traz PIX, boletos e cartões.

## Programas
- Biblioteca `finance.terms`: parcelas (centavos na última), escolha da
  condição (pedido → perfil → política) e checagem de crédito com liberação.
- `finance.save_payment_term`, `finance.simulate_payment`,
  `finance.save_credit_profile`, `finance.credit_block` (bloquear,
  desbloquear, liberar pedido), `finance.credit_report` (comando `credito`).
- `sales.create_order` (condição, permitidas, mínimo, crédito),
  `sales.invoice_order` (parcelas → títulos, ajuste, cobrança no gateway da
  condição), `field.open_order` (crédito).
