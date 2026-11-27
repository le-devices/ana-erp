# 069 — Plano

Este plano define:
- o que a projeção lê e em que granularidade;
- como cada regra real é chamada sem gravar;
- como um choque se propaga e como só o que depende dele é recalculado;
- como o desempenho e a correção são medidos.

## 1. O que já existe e é reaproveitado

| Peça | Onde | Uso na projeção |
|---|---|---|
| Parcelas de uma condição de pagamento | `finance.terms.schedule(amount, term, issue)` (031) | Pedido em carteira → títulos a receber, nas datas da condição |
| Condição do pedido ou do cliente | `finance.terms.term_for(customer, given)` | A mesma escolha que o faturamento faz |
| Motor de impostos com vigência | `tax.engine.load()`, `compute()`, `burden_rate()` (049) | Imposto de cada faturamento projetado; choque de regra |
| Planejamento de necessidades | `production.plan` (014) | Compras e ordens que o planejamento proporia |
| Carga de capacidade | `production.capacity_load` (014) | Carga por recurso e semana |
| Valores da empresa com vigência | `ana.value(name, at)` (065) | Cotações, dia de recolhimento de impostos, limites |
| Escopo de dados | políticas restritivas do banco, papel `ana_scoped` (009, D10) | A projeção roda **como a pessoa**: o banco já esconde o que ela não pode ver |
| Ensaio universal | execução em ensaio, desfeita no fim (056) | Garantia de que nada é gravado (D4) |

**O que falta e entra na T-069-01:**
- não há moeda nos pedidos de compra e de venda: só o fornecimento (`supply.supplier_item.currency`) tem moeda;
- não há cotações.
- defeito encontrado: o pedido de compra copiava o preço do fornecimento em dólar ou euro como se fosse em real,
  e o recebimento lançava esse número em estoque, contabilidade e título a pagar. A T-069-01 corrige: o pedido
  guarda a moeda, o recebimento converte pela cotação do dia e guarda a cotação usada.

**Refatoração necessária:** o planejamento (`production.plan`) hoje calcula e grava as sugestões no mesmo
`main`. Ele é dividido em `compute()` (puro: lê e devolve as sugestões) e a gravação. O `main` continua igual
para quem já usa, e a projeção chama só o `compute()`. Isso é "a mesma regra, sem fórmula paralela" (D3).

## 2. O modelo: um grafo de eventos datados

A projeção é um **grafo de eventos**. Cada evento tem:
- tipo, data, valor e moeda;
- parte (cliente ou fornecedor), item e linha de produto;
- documento de origem (`ORD-1204/2`, `OC-51/1`, `OP-88`, título 7.731);
- os eventos de que depende (pais), com a **folga** que havia entre eles na base.

| Tipo | De onde vem | Data na base |
|---|---|---|
| `cash_in` / `cash_out` | Título aberto | Vencimento + atraso medido da parte (seção 4) |
| `receipt` | Linha aberta de compra (`received_qty < quantity`) | Data prometida + atraso medido do fornecedor |
| `payable` | Recebimento projetado | Recebimento + `payment_days` do pedido de compra |
| `make` | Ordem de produção aberta e ordens que o planejamento sugeriria | Data de entrega da OP; depende dos `receipt` dos componentes (atribuição pela data, a mais antiga primeiro) |
| `delivery` | Linha do pedido de venda em carteira | Data prometida (051); se o item é fabricado, depende da `make` do item |
| `invoice` | Entrega projetada | Data da entrega |
| `receivable` | Faturamento projetado | Parcelas de `finance.terms.schedule` sobre o valor da nota + atraso medido do cliente |
| `tax` | Faturamento e recebimento projetados | Imposto do motor, recolhido no dia que o valor da empresa define (ex.: dia 20 do mês seguinte) |
| `recurring` | Despesa sem documento | Orçamento do centro de custo do mês (027) quando existe; se não, média dos últimos 3 meses de títulos a pagar sem documento de origem, por conta |
| `bank_balance` | Saldo inicial | Saldo contábil da conta de cada conta bancária hoje |

**Granularidade:** diária no cálculo. Na tela, por semana, com o dia da menor posição de caixa. Horizonte padrão
de 26 semanas, com máximo de 52 (valor da empresa).

**Resultado:** receita, custo e margem por item, linha e cliente, a partir dos `invoice` e do custo padrão
(`production.common.unit_costs`). O custo de compra em moeda estrangeira é convertido pela cotação da data.

## 3. Choques e propagação

**Choques como dado.** Um catálogo `scenario.shock_kind` traz, para cada choque:
- o nome em português e os parâmetros com tipo (moeda, percentual, data de início, parte, item, grupo,
  recurso, dias);
- a função que o aplica, na biblioteca `scenario.shocks`.

O produto entrega os choques da D2. Um choque novo precisa de dado e de uma função revisada pelo portão da spec 064.

**Aplicar um choque** altera eventos-semente:
- *fornecedor atrasa N dias* → os `receipt` desse fornecedor;
- *dólar +15% a partir de D* → o valor dos `receipt` e `payable` em USD com data ≥ D, e o custo dos itens que usam
  esses componentes;
- *cliente paga N dias depois* → os `receivable` e `cash_in` desse cliente;
- *volume +X%* → o valor e a quantidade das `delivery` do item, da linha ou do cliente; o planejamento é chamado de
  novo só para os itens afetados;
- *capacidade cai* → a carga do recurso. Uma OP que não cabe vai para a próxima semana com folga;
- *regra de imposto* → a regra em rascunho (049 ou 070) entra nos dados do motor só neste cenário;
- *valor da empresa* → a versão do valor é trocada só neste cenário.

**Propagação.** Em ordem topológica, a partir dos eventos-semente:

    nova_data(filho) = max(data_base(filho), max(nova_data(pai) + folga(pai, filho)))

Os valores que dependem de data (parcelas, imposto, câmbio) são recalculados pelas mesmas funções da base. Cada
evento alterado guarda **quem o alterou**. O caminho do efeito é a cadeia desses "porquês", até o choque:
"caixa de março −R$ 82 mil ← faturamento do pedido 1.204 adiado 12 dias ← OP 88 atrasada ← OC-51 atrasada 10 dias".

**Combinar cenários:** os choques entram em sequência sobre a mesma base. A ordem não muda o resultado, porque os
deslocamentos de data usam o máximo e os percentuais multiplicam.

**O que mais pesa:** a diferença na menor posição de caixa e na margem é repartida pelos choques e pelos
documentos que a causaram, em ordem decrescente.

**Cenário sem choques:** nenhuma semente, nenhuma propagação. O resultado é exatamente a base (CA-069-02).

## 4. Atrasos medidos (premissa, não palpite)

- **Cliente:** nos últimos 12 meses, mediana de (data do extrato − vencimento) dos títulos a receber quitados por
  conciliação bancária (`finance.bank_match` → `finance.bank_statement_line`). Com menos de 5 títulos, vale a
  mediana da empresa.
- **Fornecedor:** mediana de (data do recebimento − data prometida) das linhas de compra recebidas nos últimos
  12 meses (`supply.receipt.received_at` × `purchase_order_line.promised_date`).
- A tela mostra cada atraso usado e de onde veio. A pessoa pode sobrescrever num cenário, e isso vira um choque
  como outro qualquer.

## 5. Nunca grava (D4)

- A projeção é um programa (`scenario.project`) que só lê. Ele roda como execução **em ensaio** (056), desfeita no
  fim. Mesmo que uma regra chamada tentasse gravar, nada fica.
- O planejamento é chamado pelo `compute()` puro (seção 1), não pelo `main`.
- Só o cenário (definição e choques) e, quando a pessoa pede, o resumo do resultado são gravados, por rotinas
  próprias (`scenario.save`, `scenario.keep_result`). Fica no orçamento da spec 063 (RNF-069-01).
- O teste do CA-069-03 compara a contagem e a soma de verificação das tabelas de negócio antes e depois de simular.

## 6. Desempenho: cache da base e recálculo parcial

**Medido (bateria #88, 27/11/2026, massa de referência dentro de um ensaio):** base 0,68 s; cenário com dois
choques 0,73 s; troca de um choque 0,69 s. Refazer a projeção inteira a partir das fontes com choques fica muito
abaixo do alvo, então o cache no núcleo e o recálculo parcial descritos abaixo **não foram feitos**: voltam a ser
considerados se a medição da bateria passar do alvo.

**Medida-alvo (RNF-069-02):**
- 10 mil títulos abertos, 2 mil pedidos em carteira, 500 OPs, 26 semanas: até 10 s;
- um choque alterado: até 3 s.

**Como chegar lá:**
- **Leitura em lote.** Uma consulta por fonte, nunca por documento. Grafo previsto: cerca de 10 mil `cash_*`,
  6 mil `delivery`/`invoice`/`receivable` (pedidos com 3 linhas em média), 2 mil `receipt`/`payable`, 500 `make`,
  183 × contas bancárias.
- **Imposto por taxa efetiva.** O motor é carregado uma vez (`load()`). A taxa efetiva é calculada por combinação
  de (operação, item, UF de destino, regra vigente na data) e reaproveitada. Um choque de regra recalcula só as
  combinações que a regra alcança.
- **Base em cache no núcleo** (P20). Um processo `ana_projection` guarda o grafo da base em ETS, compactado, com a
  chave (impressão do escopo de dados da pessoa, data). O cache:
  - vale por um tempo configurável (valor da empresa, padrão 15 min);
  - cai quando o barramento de eventos do núcleo (062) avisa de gravação em título, pedido, compra ou OP;
  - mostra na tela "dados de 10h42", com o botão "Atualizar".
- **Recálculo parcial.** Mudar um choque reaplica só aquele choque. A propagação parte apenas dos eventos-semente
  dele e para quando a data e o valor de um evento não mudam.
- **Fora das telas de operação.** O cálculo roda como execução assíncrona, no limite de execuções simultâneas da
  spec 012, com no máximo 2 projeções ao mesmo tempo (valor da empresa). A tela mostra o andamento.
- **Tamanho:** o grafo vai do programa para o núcleo em formato colunar (listas paralelas), longe do limite de
  8 MiB do resultado. O que volta para a tela é só o agregado por semana e o caminho de um número quando a pessoa
  pede.

**Massa de referência e medição (T-069-09):**
- um programa `test.scenario_mass` cria, numa instância de teste, os volumes da RNF-069-02 sobre os cadastros da
  simulação de uso (067);
- um teste da bateria mede três tempos: a base fria, um cenário com dois choques e a troca de um choque;
- a bateria registra os tempos e falha acima do alvo, com 30% de margem para a variação do CI. O primeiro valor
  medido entra neste plano como referência.

## 7. Escopo e sigilo (D8)

- A projeção roda como a pessoa, então o banco filtra títulos, pedidos e projetos pelo escopo dela (009, D10). Um
  vendedor com carteira vê só os clientes dele (CA-069-05).
- **Caixa da empresa** (saldos bancários e títulos de todos) só aparece para quem pode executar
  `finance.import_statement` (a rotina do extrato bancário). Para os outros, a seção de caixa não é calculada, e a tela explica por quê.
- Valores sigilosos (custo por hora, salários) entram no cálculo do total, mas não aparecem no caminho do efeito
  nem no detalhe para quem não pode vê-los: aparecem como "valor sigiloso", como na spec 068 (D10).
- O cenário tem dono e pode ser compartilhado com um grupo. Quem abre um cenário compartilhado recalcula com o
  próprio escopo, nunca com o do dono.

## 8. Correção medida (RNF-069-03)

- **Retroteste semanal:** a projeção é refeita "como se fosse" 7 dias atrás, só com os títulos e pedidos que já
  existiam e os atrasos medidos até então, e comparada com o que entrou e saiu de verdade no banco naqueles 7 dias.
- O desvio fica na tela da base ("a projeção da semana passada errou o caixa em 4%") e vira métrica.
- Tolerância inicial de 10% no teste da bateria, com massa determinística. O número real é medido e registrado
  aqui.

## 9. Ordem das tarefas

1. **T-069-01** Moeda nos pedidos de compra e de venda (padrão: BRL) e cotações como valores da empresa com
   vigência (`financeiro.cotacao_usd`, `financeiro.cotacao_eur`: reais por unidade, na data). Nada muda para quem só usa real.
2. **T-069-02** Grafo da base, atrasos medidos, `production.plan` dividido em `compute()` e gravação; retroteste.
3. **T-069-03** Catálogo de choques, cenários guardados e combinados.
4. **T-069-04** Propagação e caminho do efeito; cache no núcleo e recálculo parcial.
5. **T-069-06** Escopo e sigilo (antes da tela, para a tela já nascer filtrada).
6. **T-069-05** Tela de cenários.
7. **T-069-09** Massa de referência e medição na bateria.
8. **T-069-08** Cenários vigiados.
9. **T-069-07** Assistente.

## 10. Decisões tomadas aqui
- O cálculo fica em Python (as regras de negócio estão lá, P5). O núcleo guarda o cache e limita a concorrência
  (P20). Não há segunda implementação das regras.
- O horizonte padrão é de 26 semanas, porque a spec fala em 6 meses.
- As despesas recorrentes vêm do orçamento quando existe. Se não existe, vêm da média de 3 meses, e a tela diz qual
  fonte foi usada.
- A atribuição de compras às OPs e de OPs aos pedidos é pela data, a mais antiga primeiro. A spec 014 não guarda a
  ligação entre documentos, e essa é a mesma ordem que o planejamento usa.
