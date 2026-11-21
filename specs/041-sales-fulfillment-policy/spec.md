# 041 — Atendimento do pedido de venda conforme a política da empresa

Situação: implementada (out/2026).

Decisões de implementação: a política e as exceções ficam em `sales.fulfillment_policy` e
`sales.fulfillment_rule` (rotina "Política de atendimento", em Vendas → Atendimento, com "Qual regra
vale?"); o padrão de fábrica é "aceitar sem estoque definido", o comportamento anterior. Todo pedido
nasce em `sales.create_order` (tela, API pública, portal, esteiras e BPM), que decide por linha com a
biblioteca `sales.fulfillment` e oferece "Simular" (o que cada linha faria e a data prometida, sem
gravar). A reserva é `reserve_qty` por linha (o que tirou do estoque mais o que o suprimento vinculado
traz; "aceitar" reserva só o que havia), e `inventory.reserved` a desconta em todas as telas. Pedido
retido ou aguardando suprimento não expede (a esteira espera com o motivo) nem fatura; volta sozinho
pela rotina `pedidos.liberar` (a cada 10 min) e logo após recebimentos de compra e entregas da
produção vinculados, do mais antigo para o mais novo (`sales.order_ready`, `flow.resume_document`).
Itens ganharam "grupo de itens" no cadastro. O cancelamento usa a simulação para mostrar o efeito.

## Problema
Cada empresa que instala o ANA atende pedidos de um jeito: há quem só venda o
que tem em estoque; quem aceite o pedido e compre do fornecedor o que faltar;
quem fabrique sob encomenda (e compre os insumos que faltarem para isso); e
quem aceite pedidos sem estoque definido e resolva depois. Hoje o pedido de
venda só avisa, transfere de outro depósito ou recusa, a escolha é feita a
cada pedido por quem digita, e nada liga o pedido à compra ou à produção que
o atende. A regra precisa ser **da empresa** (configurável por instalação,
com exceções), valer em **todos os caminhos** e disparar sozinha o que
decorre dela (P17: integrado e automatizado).

## Decisões
- **D1 — Política da instalação, com exceções.** Um modo padrão para a
  empresa e exceções por **item** (e por grupo de itens) e por **cliente**;
  a exceção mais específica vale (cliente + item > item > cliente > padrão).
  Quem digita o pedido não escolhe um modo que a política não permita.
- **D2 — Modos de atendimento quando falta estoque** (por linha do pedido):
  1. **Só com estoque — recusar**: o pedido não é aceito; a tela diz o que
     falta e onde há (outro depósito, a receber).
  2. **Só com estoque — reter**: o pedido é aceito mas fica **retido** (não
     expede nem fatura) até haver saldo; quando o estoque chega, segue
     sozinho.
  3. **Suprir pela compra**: a falta vira solicitação de compra ao
     fornecedor preferido do item, **vinculada ao pedido**; dentro da alçada
     da empresa vira ordem de compra sozinha; o recebimento é reservado para
     o pedido, que segue para expedição e faturamento.
  4. **Suprir pela produção**: a falta vira **ordem de produção** vinculada
     ao pedido; a estrutura do item é explodida e os **insumos que faltarem
     viram compras vinculadas à ordem** (e, por ela, ao pedido); concluída a
     produção, o produto é reservado para o pedido.
  5. **Suprir conforme o item**: compra ou produção pelo cadastro de
     planejamento do item (fabricado ou comprado — spec 014).
  6. **Aceitar sem estoque definido**: o pedido é aceito sem reserva e sem
     disparar suprimento; aparece em "pedidos com falta" para alguém
     decidir; expedir ou faturar sem saldo continua recusado pelo estoque.
- **D3 — Antes de suprir, transferir (opcional).** A política pode mandar
  usar primeiro o saldo de outro depósito (transferência, como hoje) e só
  suprir o que ainda faltar.
- **D4 — Reserva e vínculo.** Estoque reservado e suprimento a caminho ficam
  **ligados ao pedido** (o que chega para um pedido não atende outro); o
  saldo disponível de um item desconta o reservado.
- **D5 — Data prometida.** O pedido mostra, por linha, quanto sai do
  estoque, quanto vem de compra ou produção e a **data prevista**
  (prazo do fornecedor ou da produção, spec 013/014); atraso no suprimento
  avisa o vendedor.
- **D6 — Cancelamento.** Cancelar o pedido cancela o suprimento ainda não
  enviado ao fornecedor nem liberado na fábrica; o que já está em curso vira
  estoque livre (a política pode exigir confirmação).

## Requisitos funcionais
- **RF-041-01** Política de atendimento (Administração → Vendas): modo
  padrão, transferir antes de suprir, alçada para a compra virar ordem
  sozinha, confirmação no cancelamento; exceções por item, grupo de itens,
  cliente e cliente + item, com a origem da regra visível ("vale a exceção
  do item X").
- **RF-041-02** No pedido, cada linha mostra o disponível (estoque −
  reservado), o que vai acontecer pela política e a data prometida, antes de
  confirmar; o modo só pode ser trocado para outro permitido.
- **RF-041-03** Reserva por pedido e por linha; o saldo disponível em todas
  as telas, na API e no portal desconta o reservado.
- **RF-041-04** Suprimento pela compra: solicitação vinculada ao pedido e à
  linha, fornecedor preferido, quantidade faltante respeitando lote mínimo e
  múltiplo; dentro da alçada, ordem emitida sozinha (o restante segue a
  aprovação da spec 013); o recebimento reserva para o pedido.
- **RF-041-05** Suprimento pela produção: ordem de produção vinculada;
  explosão da estrutura com os saldos atuais; insumos em falta viram compras
  vinculadas à ordem; liberação da ordem quando os insumos chegam (ou pela
  regra da produção); conclusão reserva para o pedido.
- **RF-041-06** Pedido retido segue sozinho quando o estoque ou o
  suprimento vinculado chega (esteira de venda, spec 030; etapas do pedido
  mostram "aguardando compra/produção", spec 020).
- **RF-041-07** Rastreabilidade: do pedido se chega à compra, à ordem de
  produção e às compras de insumos, e de volta (documentos navegáveis, spec
  035); a tela "Pedidos com falta" lista o que espera suprimento ou decisão.
- **RF-041-08** A mesma regra vale em todos os caminhos: tela, API pública,
  portal, esteiras, BPM e importação; uma tentativa fora da política é
  recusada com o motivo.
- **RF-041-09** Cancelamento conforme D6, com o efeito mostrado antes de
  confirmar.

## Requisitos não funcionais
- **RNF-041-01** A decisão de atendimento de um pedido de 200 linhas, com
  explosão de estrutura de até 5 níveis, em menos de 2 s.
- **RNF-041-02** Pedido, reserva e suprimento disparado na mesma transação:
  ou tudo, ou nada.

## Critérios de aceite
- **CA-041-01** Com "só com estoque — recusar", um pedido acima do saldo é
  recusado mostrando a falta; com "reter", é aceito e não expede; ao entrar
  o estoque, segue sozinho.
- **CA-041-02** Com "suprir pela compra", faltando 5 unidades nasce a
  solicitação de 5 (ou o lote mínimo) vinculada ao pedido; dentro da alçada
  já é ordem; o recebimento reserva para o pedido e a esteira expede.
- **CA-041-03** Com "suprir pela produção", nasce a ordem de produção
  vinculada; um insumo em falta gera compra vinculada à ordem; concluída a
  ordem, o produto fica reservado para o pedido.
- **CA-041-04** Com "aceitar sem estoque definido", o pedido entra sem
  reserva e aparece em "Pedidos com falta"; faturar sem saldo continua
  recusado.
- **CA-041-05** Exceção por item vence o padrão; exceção cliente + item
  vence a do item; a tela diz qual regra valeu.
- **CA-041-06** Um pedido pela API pública segue a mesma política que pela
  tela.
- **CA-041-07** Cancelar o pedido cancela a solicitação ainda não enviada e
  mantém como estoque livre o que já foi recebido.

## Fora do escopo (por ora)
- Disponibilidade prometida com alocação de quotas por canal ou região
  (planejamento de cotas — usa a grade de planejamento da spec 020, RF-020-15).
- Entrega parcial por linha com datas diferentes (o pedido sai quando todas
  as linhas estiverem disponíveis, salvo expedição parcial manual).
