# 030 — Esteiras de processos com etapas automáticas

## Problema
Os processos existem como passos separados (pedido, expedição, faturamento,
cobrança; solicitação, ordem, recebimento; …). O usuário quer esteiras em que
cada etapa seguinte acontece sozinha quando a anterior termina — ou fica para
uma pessoa, conforme a regra da empresa.

## Histórias
- **H1** Como gestor, escolho, por esteira e etapa, automático ou manual, e
  condições (ex.: faturar sozinho só pedidos até R$ 5 mil; cobrar por PIX).
- **H2** Venda: pedido confirmado → reserva/baixa → expedição → faturamento →
  cobrança (títulos e gateway) → baixa do recebimento (conciliação).
- **H3** Compras: solicitação aprovada → ordem → recebimento → título a pagar.
- **H4** Produção: sugestões aprovadas → ordens liberadas → requisição.
- **H5** Campo: OS concluída → fatura → cobrança.
- **H6** Vejo cada documento na esteira (onde está, quem/que regra moveu,
  falhas e o que falta), reprocesso etapas que falharam.

## Requisitos funcionais
- **RF-030-01** Catálogo de esteiras e etapas do produto (P13: o cliente só
  configura), cada etapa = um programa existente.
- **RF-030-02** Regras por etapa: modo (`auto` | `manual`), condição
  (expressão sobre o documento: valor, cliente, forma), dono (robô ou usuário).
- **RF-030-03** Gatilho: quando uma etapa termina, a próxima automática é
  enfileirada na caixa de saída interna (spec 017) — mesma transação, entrega
  confiável, novas tentativas; nunca em linha com a etapa anterior.
- **RF-030-04** Instância por documento (`flow.instance`, `flow.step`):
  situação de cada etapa, horários, execução, erro.
- **RF-030-05** Painel da esteira (quadro por etapa) e reprocessar/pular com
  justificativa.

## Critérios de aceite
- **CA-030-01** Com venda toda automática, criar um pedido termina com
  estoque baixado, expedição, fatura e títulos, sem outra ação.
- **CA-030-02** Etapa manual para a esteira até alguém agir; ao agir, as
  seguintes automáticas continuam.
- **CA-030-03** Falha numa etapa (ex.: falta de estoque) aparece no painel e
  reprocessar depois da correção conclui.
- **CA-030-04** Cliente bloqueado (spec 031) para a esteira na etapa de
  faturamento com o motivo.

## Decisões
- As esteiras nascem **desligadas** e com faturamento/expedição manuais
  (P13): ligar muda o comportamento da operação, decisão do dono.
- Uma etapa sabe se está concluída por uma consulta do produto, não por quem
  a fez: o que alguém fizer à mão, fora da esteira, faz a esteira andar (a
  verificação de esperas roda a cada 30 s).
- Condição que não se cumpre não falha: a etapa automática passa a esperar
  uma pessoa. Recusa de negócio (cliente bloqueado, falta de estoque) para a
  esteira com o motivo; falha técnica tem novas tentativas com espera.
- Expedição automática usa a transportadora padrão (marcada no cadastro da
  transportadora).

## Recebimento e pagamento como etapas automáticas (T-030-06b)
As etapas de recebimento (venda, campo) e de pagamento (compra) rodam
`finance.reconcile_document`: os títulos em aberto do documento são procurados
nas linhas abertas do extrato de todas as contas ativas, com as regras da
conciliação bancária. Só o que é certo é baixado (identificador da cobrança ou
documento do título na linha, valor exato, uma linha para um título); um
crédito que bate só por valor e data nunca é baixado aqui — a etapa espera e
diz qual crédito pode ser, para uma pessoa confirmar na bancada. A espera
mostra o motivo (o que o programa devolve em `waiting`). Pagamentos que chegam
depois são baixados pela importação do extrato (spec 038) e a varredura conclui
a etapa. A migração 044 só muda etapas que continuam como vieram (aguardando,
sem programa).
