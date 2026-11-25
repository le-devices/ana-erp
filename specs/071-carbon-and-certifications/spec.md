# 071 — Carbono por item e lote, e fornecedores certificados

Situação: especificada (nov/2026).

## Problema
Grandes compradores, exportação e financiamento cada vez mais exigem que a
empresa saiba a **pegada de carbono** do que vende e prove que compra de
fornecedores em situação regular (ambiental e trabalhista). Hoje isso se faz
com planilhas paralelas e consultorias no fim do ano: os números não batem
com o ERP e chegam tarde. Ao mesmo tempo, comprar de um fornecedor que
perdeu uma licença ambiental ou entrou numa lista restritiva expõe a empresa
a multas e a risco de imagem, e ninguém percebe até ser tarde.

O ANA já registra o que é preciso para calcular:
- notas e recebimentos de compra por item e quantidade;
- fretes com distância (spec 032);
- horas de máquina e de bancada por ordem de produção (spec 014);
- a estrutura do produto;
- rastreabilidade por lote e número de série (spec 054).

Faltam os fatores de emissão, o cálculo e as certificações dos fornecedores.

## Decisões
- **D1 — Fatores de emissão são dado, com vigência e fonte.** Fatores por
  categoria de item ou NCM (kg CO₂e por kg, unidade ou R$), por modal de
  transporte (por t·km), por energia (kWh da rede, que varia por ano e
  região) e por combustível. Cada fator tem fonte (inventário nacional,
  base pública ou declaração do fornecedor), unidade e vigência, como as
  regras fiscais (P21). Os fatores chegam em pacotes e podem ser ajustados
  com justificativa.
- **D2 — Fator declarado pelo fornecedor prevalece.** Um fornecedor pode
  declarar a pegada do próprio item (com documento anexado e validade). A
  declaração vale sobre o fator genérico enquanto estiver válida, e o
  resultado mostra qual foi usado.
- **D3 — Cálculo automático no fato.** Cada fato do ERP calcula a própria
  emissão:
  - o recebimento de compra pela quantidade e pelo fator do item;
  - o frete pela distância, pelo peso e pelo modal;
  - a ordem de produção pelas horas de recurso × consumo do recurso (kWh) ×
    fator de energia, mais o que os componentes consumidos carregam.

  Pela estrutura e pela rastreabilidade, a pegada sobe até o **lote** e o
  **número de série** produzidos, e daí até o item vendido. Ninguém digita
  emissão à mão.
- **D4 — Escopos do padrão de mercado.** O resultado é classificado nos
  escopos usuais:
  - escopo 1: combustível próprio;
  - escopo 2: energia comprada;
  - escopo 3: o que vem dos fornecedores e do transporte contratado.

  Os nomes são os do padrão, mas o ANA não pretende certificar o
  inventário: entrega os números rastreáveis que o auditor externo pede.
- **D5 — Gravar pouco.** A emissão de cada fato é gravada uma vez, junto com
  o fato (uma coluna ou uma linha no mesmo comando), e nunca recalculada
  linha a linha. Uma mudança de fator vale para os fatos novos. Recalcular
  o passado é uma rotina explícita, em lote, com resumo do efeito. Os totais
  por item, lote, período e escopo são agregados incrementais da spec 007,
  sem varrer o histórico (P15).
- **D6 — Certificações do fornecedor com validade.** O cadastro do
  fornecedor (spec 040) ganha certificações e licenças: tipo (licença
  ambiental, certidões, ISO 14001, selo de origem…), número, órgão, validade
  e documento no repositório de arquivos (spec 016). Os tipos exigidos são
  política da empresa, por categoria de item ou de fornecedor ("fornecedor
  de madeira exige DOF válido").
- **D7 — Bloqueio por política, com exceção controlada.** Certificação
  exigida vencida, ausente ou cassada bloqueia novos pedidos de compra e
  novos recebimentos daquele fornecedor, para os itens que a exigem. O
  bloqueio usa a mesma política e a mesma verificação no banco que o crédito
  e o cadastro já usam. Pedidos abertos viram tarefa para Compras decidir.
  Uma exceção pontual exige justificativa, outra pessoa que aprove (quatro
  olhos), prazo e fica na auditoria.
- **D8 — Avisar antes de vencer.** Certificações a vencer em 60, 30 e
  7 dias viram tarefa para Compras e pedido automático de renovação ao
  fornecedor, por e-mail (spec 044) ou pelo portal (spec 016). O fornecedor
  envia o documento novo pelo portal, e Compras confere e aprova.
- **D9 — Listas públicas por conector.** Consultas a listas públicas
  restritivas (cadastro de empregadores com trabalho análogo à escravidão,
  áreas embargadas e autuações ambientais, situação cadastral na Receita)
  rodam por conector (spec 017), agendadas e na criação do fornecedor. Um
  achado bloqueia o fornecedor com o motivo, a fonte e a data, até que uma
  pessoa revise. As fontes são catálogo, como na spec 070.
- **D10 — Relatórios para quem pede.** Pegada por item, lote, cliente e
  período, por escopo, com as fontes dos fatores. Ficha do lote ou número de
  série com a pegada (para anexar à venda ou à exportação). Situação dos
  fornecedores (regulares, a vencer, bloqueados). Painel com tendência e
  com o que mais emite.

## O que a pessoa deixa de fazer (P19)
- Manter planilhas paralelas de emissões e refazer o inventário no fim do
  ano.
- Controlar à mão a validade das licenças e certidões dos fornecedores.
- Consultar listas públicas fornecedor a fornecedor.
- Lembrar o fornecedor de renovar documentos.

## Requisitos funcionais
- **RF-071-01** Fatores de emissão como dado com vigência, fonte e unidade,
  em pacotes e ajustáveis com justificativa (D1).
- **RF-071-02** Declaração de pegada pelo fornecedor, com documento e
  validade, que prevalece sobre o fator genérico (D2).
- **RF-071-03** Emissão calculada em cada fato (compra, frete, produção) e
  propagada até o lote, o número de série e a venda (D3), classificada por
  escopo (D4).
- **RF-071-04** Gravação única por fato, recálculo do passado só por rotina
  em lote e totais incrementais (D5).
- **RF-071-05** Certificações e licenças do fornecedor com validade e
  documento, e exigências por política (D6).
- **RF-071-06** Bloqueio de compra e de recebimento por política, com
  exceção por quatro olhos e tarefa para os pedidos abertos (D7).
- **RF-071-07** Avisos e pedidos de renovação antes do vencimento, com envio
  pelo portal (D8).
- **RF-071-08** Consulta a listas públicas por conector, agendada e na
  criação do fornecedor (D9).
- **RF-071-09** Relatórios, ficha do lote e painel (D10).

## Requisitos não funcionais
- **RNF-071-01 (escrita).** Calcular a emissão acrescenta no máximo o
  orçamento medido por fato (uma coluna ou uma linha no mesmo comando). Sem
  fator configurado, não acrescenta nada. Entra no orçamento da spec 063.
- **RNF-071-02 (desempenho).** O cálculo no fato não deixa o recebimento,
  o apontamento de produção nem o frete mais de 5% mais lentos (medido). O
  painel lê agregados.
- **RNF-071-03 (segurança).**
  - O bloqueio vale no banco, e não só na tela: nenhuma rotina, API ou
    integração cria pedido ou recebimento bloqueado.
  - Documentos de certificação seguem as permissões do repositório de
    arquivos.
  - Consultas externas não enviam dados além do CNPJ do fornecedor.
- **RNF-071-04 (rastreabilidade).** Todo número de emissão leva ao fato de
  origem, ao fator usado e à fonte do fator.

## Critérios de aceite
- **CA-071-01** Receber 100 kg de um item com fator de 2 kg CO₂e/kg registra
  200 kg CO₂e no escopo 3. Produzir um lote que consome esse item e
  2 horas de máquina de 5 kW mostra a pegada do lote com as duas parcelas e
  as fontes.
- **CA-071-02** Um fornecedor que declara 1,5 kg CO₂e/kg com documento
  válido faz o recebimento seguinte usar 1,5. Vencida a declaração, volta o
  fator genérico.
- **CA-071-03** Uma licença exigida vencida bloqueia um novo pedido de
  compra daquele fornecedor para os itens que a exigem, também pela API.
  Os pedidos abertos viram tarefa para Compras.
- **CA-071-04** Uma exceção ao bloqueio exige outra pessoa que aprove, tem
  prazo e fica na auditoria. Vencido o prazo, o bloqueio volta.
- **CA-071-05** Uma certificação a 30 dias de vencer gera tarefa e pedido de
  renovação. O documento novo, enviado pelo portal e aprovado, desbloqueia o
  fornecedor.
- **CA-071-06** Um fornecedor encontrado numa lista pública restritiva é
  bloqueado com fonte, data e motivo, e só volta depois da revisão de uma
  pessoa.
- **CA-071-07** Uma mudança de fator não altera emissões já gravadas. A
  rotina de recálculo mostra o efeito antes de aplicar e grava em lote.
