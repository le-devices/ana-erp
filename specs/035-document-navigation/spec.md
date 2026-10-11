# 035 — Documentos navegáveis: abrir qualquer documento a partir de onde ele aparece

## Problema
Listas de faturas, pedidos, OS, ordens de compra e de produção, expedições e
transferências mostram o número do documento, mas não é possível clicar para
ver o conteúdo (itens, valores, parcelas, situação, documentos ligados). O
usuário precisa saber qual rotina abrir e digitar o número.

## Histórias
- **H1** Clico numa linha (ou no número) e vejo o documento: cabeçalho,
  itens, totais, situação e histórico.
- **H2** Do documento vou para os documentos ligados (pedido → expedições,
  faturas/parcelas, cobranças, lançamento contábil, esteira; fatura → pedido
  ou OS de origem, cobranças, PDF) e para o próximo passo.
- **H3** O cliente no portal abre as próprias faturas, pedidos e OS — nunca
  os de outro cliente.

## Requisitos funcionais
- **RF-035-01** Tabelas aceitam, por linha, um "abrir" (`_open`): a linha
  inteira fica clicável (mouse, teclado com Enter, leitor de tela), sem
  atrapalhar os botões da linha.
- **RF-035-02** Visualizador único de documentos (`docs.view`, comando
  `doc`): pedido de venda, título/fatura, OS, solicitação e ordem de compra,
  ordem de produção, expedição, transferência, lançamento contábil.
- **RF-035-03** Cada documento mostra relacionados com "abrir" e ações do
  próximo passo; a fatura oferece o PDF.
- **RF-035-04** Portal: só documentos da própria empresa (cliente).
- **RF-035-05** As rotinas do produto que listam documentos passam a usar o
  "abrir" (faturas, bancadas, relatórios, esteiras, crédito).

## Critérios de aceite
- **CA-035-01** Em Minhas faturas, clicar numa fatura abre o título com
  valor, parcelas, vencimentos, situação, cobrança e o pedido de origem.
- **CA-035-02** Do pedido abrem-se as faturas e as expedições dele.
- **CA-035-03** Conta do portal não abre documento de outro cliente (não
  encontrado).
- **CA-035-04** A linha clicável funciona pelo teclado.
- **RF-035-06** A fatura (pedido ou OS) tem PDF — itens, parcelas,
  vencimentos e dados de pagamento —, gerado no faturamento e guardado na
  pasta "Faturas" do cliente; o título e Minhas faturas abrem o PDF (o
  portal só os da própria empresa).
