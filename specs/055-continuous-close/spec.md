# 055 — Fechamento contínuo

Situação: especificada (nov/2026).

## Problema
O fechamento do mês costuma levar dias de conferência. No ANA, cada razão
auxiliar já se concilia sozinho com a contabilidade (spec 038, P17) e há
rotinas de fechamento. Falta transformar isso num **fechamento contínuo**:
o mês está sempre "quase fechado", e fechar é confirmar uma lista que já
está verde.

## Decisões
- **D1 — Painel do fechamento.** Uma lista de verificações por período
  (conciliações de clientes, fornecedores, estoque, bancos, em elaboração;
  documentos pendentes; lançamentos sem centro de custo; notas de fornecedor
  sem confronto; extratos não conciliados; depreciação; provisões), cada uma
  calculada sozinha, com situação, valor da diferença e o link para resolver.
- **D2 — Fecha quando está verde.** Fechar o período só com tudo verde ou com
  justificativa registrada para cada exceção; o período fechado recusa
  lançamentos (estorno no período aberto, P17).
- **D3 — Automático durante o mês.** As verificações rodam diariamente
  (spec 018) e as pendências viram tarefas para o responsável (spec 051);
  no último dia sobra pouco ou nada.
- **D4 — Pacote do período.** Ao fechar, gera os relatórios (balancete, DRE
  gerencial, conciliações) em PDF no repositório, para o contador.

## Requisitos funcionais
- **RF-055-01** Painel do fechamento por período (D1) com responsável por item.
- **RF-055-02** Fechamento com verificação e justificativas; reabertura com
  permissão e auditoria (D2).
- **RF-055-03** Verificações diárias e tarefas de pendência (D3).
- **RF-055-04** Pacote do período no repositório (D4), enviável por e-mail
  (spec 044).

## Critérios de aceite
- **CA-055-01** Com um extrato não conciliado, o item fica vermelho com o
  valor e o link; conciliado, fica verde sozinho.
- **CA-055-02** Fechar com item vermelho exige justificativa; período fechado
  recusa lançamento.
- **CA-055-03** O pacote do período aparece no repositório e pode ser enviado.
