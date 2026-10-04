# 027 — Centros de custo integrados à contabilidade

Situação: implementada

## Problema
O resultado só por conta contábil não diz **onde** a empresa ganha ou perde
dinheiro. Centros de custo (engenharia, comercial, administrativo, cada
projeto…) dão a visão gerencial: receitas e despesas por área, orçamento ×
realizado, custos compartilhados distribuídos de forma justa.

## Requisitos funcionais
- **RF-027-01** Cadastro de centros de custo em hierarquia (código, nome,
  centro-pai, tipo — operacional, administrativo, comercial, projeto, outro
  —, responsável, ativo). O produto traz só o centro `GERAL`; os demais são
  do cliente (P13).
- **RF-027-02** Toda linha de lançamento pode ter centro de custo. Cada conta
  tem uma política: `required` (receitas e despesas, por padrão), `optional`
  ou `none` (contas patrimoniais). Linha de conta `required` sem centro
  recebe o centro padrão do documento ou, na falta, o da empresa; conta
  `none` não aceita centro; centro inativo não recebe lançamento novo. Tudo
  garantido no banco (gatilho), valendo para qualquer programa.
- **RF-027-03** Origem automática do centro: pedido de venda (informado ou
  o do depósito), projeto (cada projeto tem o seu), padrão da empresa. O
  estorno copia o centro do lançamento original.
- **RF-027-04** Lançamento manual com centro por linha, validação de partidas
  dobradas e das políticas.
- **RF-027-05** Orçamento por centro × conta × mês e relatório orçado ×
  realizado com variação.
- **RF-027-06** Rateio de custos compartilhados: regra (centro de origem,
  contas, centros de destino com percentuais que somam 100 %); a execução do
  mês gera um lançamento que transfere as despesas do centro de origem para
  os destinos (por conta), com prévia sem gravar e proteção contra rateio em
  dobro do mesmo mês.
- **RF-027-07** Relatórios: balancete filtrado por centro; resultado
  gerencial por centro (receitas, despesas, resultado, margem) com
  consolidação da hierarquia (o pai soma os filhos), por período, com
  gráficos.

## Critérios de aceite
- **CA-027-01** Linha de receita sem centro recebe o padrão; conta
  patrimonial com centro é recusada; centro inativo é recusado.
- **CA-027-02** Faturar pedido grava receita e custo no centro do pedido
  (ou do depósito); faturar projeto grava no centro do projeto; cancelar copia
  os centros.
- **CA-027-03** O resultado por centro consolida filhos no pai e mostra
  orçado × realizado com variação.
- **CA-027-04** Rateio 60 %/40 % transfere as despesas do mês, fica
  balanceado, a prévia não grava e repetir o mês é recusado.
- **CA-027-05** Balancete filtrado por centro mostra só os lançamentos dele.
- **CA-027-06** Lançamento manual desbalanceado é recusado.
