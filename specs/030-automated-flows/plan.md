# 030 — Plano técnico

## Dados (migração `031_flows.sql`, esquema `flow`)
- `flow.definition`: catálogo do produto (código, nome, documento seguido,
  SQL dos fatos do documento, SQL de cancelamento, SQL dos documentos em
  aberto), `active` (padrão desligada) e `run_as` (robô dono, P14).
- `flow.step`: etapas (programa, parâmetros com `{{fato}}`, SQL de
  "concluída", modo `auto` | `manual` | `wait`, condição — regras
  `{field, op, value}` sobre os fatos —, tentativas).
- `flow.instance` / `flow.instance_step`: uma instância por documento;
  situação, tentativas, fila (`next_at`), concessão (`lease_until`),
  execução, erro, como terminou (automática, por uma pessoa, já concluída,
  pulada), quem e por quê.
- Funções (SECURITY DEFINER): `flow.start` (chamada por gatilho na inserção
  do documento — mesma transação), `flow.advance`, `flow.skip`,
  `flow.retry`, `flow.include_open`. Programas só leem as tabelas e agem por
  essas funções.
- Catálogo: Venda (expedição → faturamento → cobrança → recebimento),
  Compras (aprovação → ordem → recebimento → pagamento), Campo (agendamento
  → execução e aceite → faturamento → cobrança → recebimento), Produção
  (liberação → requisição → fabricação → encerramento).
- `logistics.policy.default_carrier` (expedição sem escolha).

## Núcleo — `ana_flows`
- Só no líder do agendamento; acorda pelo canal `ana_flow` e a cada 5 s.
- Reivindica etapas prontas com `FOR UPDATE SKIP LOCKED` e concessão de
  15 min (até 8 ao mesmo tempo); para cada uma: fatos → cancelado? →
  concluída? → espera (manual, condição, evento) ou executa o programa como
  o robô (ou como quem pediu "executar agora"). Sucesso conclui e avança
  (se a etapa ainda não terminou, espera); falha técnica → nova tentativa
  (30 s × 2ⁿ); recusa de negócio → falha com o motivo.
- Varredura a cada 30 s das etapas esperando ou com falha.
- Retenção (spec 024): instâncias concluídas/canceladas.

## Programas
- `flows.board` (comando `esteiras`): indicadores, quadro por etapa com os
  documentos em aberto e ações (fazer agora — abre a rotina da etapa com o
  documento —, executar automaticamente, reprocessar, pular com motivo),
  falhas e histórico de um documento.
- `flows.configure` (comando `esteira_config`, admin): ligar/desligar,
  incluir em aberto, robô, modo e condições por etapa.
- `flows.act`, `flows.lookup`, biblioteca `flows.common`,
  `finance.charge_document` (cobra os títulos abertos de um documento).
