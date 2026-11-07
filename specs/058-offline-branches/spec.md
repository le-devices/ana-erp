# 058 — Filiais que operam sem internet

Situação: especificada (nov/2026) — depende de decisão do dono do produto (há clientes com filiais em locais de conexão ruim?).

## Problema
Lojas, obras e fábricas em locais com internet instável param quando o ERP
central fica inacessível. A distribuição do Erlang e o modelo de mensagens
idempotentes (spec 017) permitem um nó local que continua operando e
sincroniza depois.

## Decisões (a confirmar)
- **D1** Nó de filial com subconjunto de dados (cadastros, estoque da filial,
  preços) e operações permitidas offline (venda balcão, recebimento,
  apontamento), com numeração própria de documentos.
- **D2** Sincronização por fila idempotente nos dois sentidos; conflitos
  resolvidos por regra declarada (o central vence em cadastros; movimentos
  da filial são sempre aceitos e reconciliados).
- **D3** Limites claros: crédito e estoque de outras filiais são estimados
  offline e confirmados na volta.

## Critérios de aceite (a detalhar)
- **CA-058-01** Filial desconectada vende e recebe; ao reconectar, documentos
  e estoque aparecem no central sem duplicar.
