# 031 — Condições de pagamento, crédito e bloqueio por inadimplência

## Problema
Hoje todo título nasce com um único vencimento (prazo em dias). Empresas
oferecem várias formas e prazos (PIX à vista, boleto 30/60/90, cartão em até
12×, crédito direto) e precisam impedir novas vendas a quem está inadimplente
ou acima do limite de crédito.

## Histórias
- **H1** Como financeiro, cadastro condições de pagamento: forma (PIX, boleto,
  cartão de crédito, cartão de débito, crédito direto, dinheiro, transferência),
  parcelas com dias e percentuais, entrada, desconto ou acréscimo, taxa da
  operadora, e quais clientes podem usar.
- **H2** Como vendedor, escolho a condição no pedido; o sistema mostra as
  parcelas e o total.
- **H3** Ao faturar, cada parcela vira um título com seu vencimento; PIX,
  boleto e cartão podem gerar cobrança no gateway (spec 017).
- **H4** Como financeiro, defino limite de crédito por cliente e a tolerância
  de atraso; cliente com título vencido além da tolerância, ou acima do
  limite, fica bloqueado para novos pedidos e faturamentos.
- **H5** Como gestor, bloqueio e desbloqueio manualmente (motivo, validade),
  e libero um pedido específico com justificativa; tudo auditado.

## Requisitos funcionais
- **RF-031-01** `finance.payment_term`: código, nome, forma, parcelas
  (`[{"days": 30, "pct": 50}, …]`, soma 100), entrada %, desconto/acréscimo %,
  taxa da operadora %, valor mínimo, ativa; formas disponíveis por cliente
  (todas, ou lista).
- **RF-031-02** Pedido de venda guarda a condição; simulação mostra parcelas.
- **RF-031-03** Faturamento gera N títulos (`installment`, `of`), centavos
  na última parcela; título guarda a forma; cobrança por gateway opcional.
- **RF-031-04** Crédito por cliente (`finance.credit_profile`): limite,
  tolerância de atraso (dias), bloqueio automático liga/desliga.
- **RF-031-05** Situação de crédito calculada (aberto + pedidos em aberto ×
  limite; vencidos além da tolerância) numa função do banco; bloqueio manual
  com motivo e validade; liberação pontual de um pedido.
- **RF-031-06** Pedido e faturamento recusam cliente bloqueado
  (`CUSTOMER_BLOCKED`), salvo liberação; tela de crédito e inadimplência.

- **RF-031-07** Tela de venda utilizável sem conhecer o sistema: cliente,
  depósito e condição são listas; itens numa grade (item, quantidade, preço)
  com o saldo do depósito e dos outros depósitos ao escolher o item, alerta
  quando falta e total da grade; se faltar no depósito, o pedido só avisa
  (com ação "Transferir de X"), pede a transferência ou é recusado.
- **RF-031-08** Todo campo de formulário e toda coluna de grade têm rótulo em
  português (teste automático); campos de cliente, OS, técnico, conta,
  depósito etc. viram listas; listas de linhas viram grades.
- **RF-031-09** Campos de data, data e hora, e hora têm ao lado botão de
  calendário/relógio e "hoje"/"agora" — preenchimento sem digitar; números
  aceitam vírgula decimal ("4,79", "1.234,56").

## Critérios de aceite
- **CA-031-01** Condição 3× (30/60/90) em fatura de 100,00 gera 33,33 +
  33,33 + 33,34 com vencimentos corretos.
- **CA-031-02** Cliente com título vencido há 10 dias e tolerância de 5 é
  recusado em novo pedido; liberação pontual permite aquele pedido.
- **CA-031-03** Pedido que excederia o limite de crédito é recusado.
- **CA-031-04** Desbloqueio manual registra quem, quando e por quê.
- **CA-031-05** Pedido com falta no depósito: "recusar" falha com
  `INSUFFICIENT_STOCK`, "transferir" despacha do depósito que tem saldo, "só
  avisar" cria e lista a falta; a lista de itens mostra o saldo em formato
  brasileiro.

## Decisões
- O bloqueio automático nasce **desligado** (`finance.credit_policy.auto_block
  = false`): ligar de saída bloquearia de repente clientes com títulos antigos
  em instalações existentes. O administrador liga na política (e por cliente).
- O bloqueio impede **novos pedidos de venda**, o **faturamento de pedidos** e
  a **abertura de ordens de serviço**; faturas de projetos (contratos em
  andamento) não são bloqueadas.
