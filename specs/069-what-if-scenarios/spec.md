# 069 — Cenários "e se…": gêmeo financeiro e operacional da empresa

Situação: especificada (nov/2026); plano em plan.md (27/11/2026).

## Problema
O ERP mostra o passado (relatórios) e o presente (painéis), mas não deixa
**testar o futuro** antes de decidir. Perguntas do dia a dia de quem dirige
uma empresa ficam sem resposta rápida, ou viram planilhas paralelas que
ninguém mantém:
- "O que acontece com o meu caixa nos próximos 6 meses se o dólar subir 15%
  e o meu principal fornecedor atrasar 10 dias?"
- "Se eu der 5 dias a mais de prazo ao maior cliente, preciso de capital de
  giro? Quanto?"
- "Se a alíquota do IBS mudar no ano que vem, quanto muda a minha margem por
  linha de produto?"

O ANA já tem as peças: carteira de pedidos, compras abertas, planejamento de
produção e de capacidade (spec 014), contas a receber e a pagar com
condições de pagamento (spec 031), motor de impostos com vigência (spec 049),
valores da empresa com vigência (spec 065) e simulação de processos
(spec 039). Falta juntar tudo numa **projeção** e permitir **variar as
premissas** e ver o efeito em cascata.

## Decisões
- **D1 — Projeção base primeiro.** Uma projeção diária e semanal do futuro,
  a partir do que já está no ERP:
  - caixa: saldos bancários, títulos a receber e a pagar, pedidos em
    carteira e compras abertas convertidos em títulos pelas condições de
    pagamento, impostos a recolher pelo motor da spec 049, folha e despesas
    recorrentes;
  - operação: necessidades de compra e de produção, carga de capacidade e
    datas de entrega prometidas (spec 014);
  - resultado: receita, custo e margem por item, linha e cliente.

  Atrasos históricos (cliente que paga em média 8 dias depois, fornecedor
  que entrega 5 dias depois) entram como premissas medidas, e não como
  palpite. A projeção base é útil sozinha, sem nenhum cenário.
- **D2 — Cenário = premissas nomeadas sobre a base.** Um cenário é um
  conjunto de **choques**, de uma lista fechada e extensível por dado:
  - câmbio (uma moeda varia X% a partir de uma data);
  - preço de compra de um item ou grupo varia X%;
  - um fornecedor atrasa N dias ou deixa de entregar;
  - um cliente atrasa o pagamento N dias ou deixa de pagar;
  - prazo de recebimento ou de pagamento muda;
  - volume de vendas de um item, linha ou cliente varia X%;
  - capacidade de um recurso cai (máquina parada, técnico de férias);
  - uma regra de imposto muda a partir de uma data (rascunho de regra da
    spec 049 ou da spec 070);
  - um valor da empresa muda (spec 065).

  Cenários podem ser combinados ("dólar +15%" + "fornecedor X atrasa
  10 dias") e guardados para comparar depois.
- **D3 — Impacto em cascata.** Um choque se propaga pelas mesmas regras que
  o ERP usa de verdade:
  - um atraso do fornecedor desloca o recebimento, que atrasa a produção,
    que atrasa a entrega, que desloca o faturamento, que desloca o
    recebimento;
  - o câmbio muda o custo de compra, que muda o custo do produto, a margem
    e os impostos sobre o valor.

  Nada de fórmula paralela: a projeção chama o planejamento (spec 014), as
  condições de pagamento (spec 031) e o motor de impostos (spec 049) em modo
  de simulação. O caminho do efeito fica visível ("caixa de março −R$ 82 mil
  ← faturamento do pedido 1.204 adiado 12 dias ← OP 88 atrasada ← compra
  OC-51 atrasada 10 dias").
- **D4 — Simular nunca grava.** O cálculo roda numa cópia em memória dos
  dados necessários e não grava nada no banco além do cenário (premissas)
  e, se a pessoa pedir, um resumo do resultado para comparar depois (P15).
  Nenhum documento, título ou reserva é criado, e o ensaio universal
  (spec 056) garante isso nas rotinas chamadas.
- **D5 — Comparar e decidir.** Tela de cenários com:
  - base × cenários lado a lado: saldo de caixa por semana com a menor
    posição e quando acontece, necessidade de capital de giro, margem
    por linha, entregas em risco e carga de capacidade;
  - o que mais pesa no resultado ("80% do efeito vem do item X");
  - "o que fazer": ações sugeridas a partir do resultado, como antecipar a
    compra, renegociar o prazo ou buscar outro fornecedor do item (spec 013),
    cada uma levando à rotina que a executa.
- **D6 — Perguntar em português.** O assistente (spec 052) monta o cenário a
  partir da pergunta ("e se o dólar subir 15% e o fornecedor X atrasar
  10 dias?"). Antes de calcular, mostra as premissas que entendeu para a
  pessoa conferir. Ele só usa os choques da lista e as permissões de quem
  pergunta.
- **D7 — Cenários vigiados.** Um cenário pode ser recalculado
  periodicamente (spec 018) e virar alerta ("no cenário 'dólar +15%', o caixa
  fica negativo em 6 semanas — antes eram 9"). As regras da spec 051 podem
  usar a métrica.
- **D8 — Permissões e sigilo.** Cada pessoa só simula com os dados que pode
  ver (escopo de dados): um vendedor vê a carteira dele, e o caixa da
  empresa é só para quem tem acesso ao financeiro. Valores sigilosos (custo
  por hora, salários) entram no cálculo, mas só aparecem para quem pode
  vê-los. O cenário tem dono e pode ser compartilhado com um grupo.

## O que a pessoa deixa de fazer (P19)
- Montar e manter planilhas de projeção de caixa e de cenário.
- Perguntar a várias áreas "e se…" e juntar as respostas à mão.
- Descobrir tarde que o caixa vai faltar: o cenário vigiado avisa antes.

## Requisitos funcionais
- **RF-069-01** Projeção base de caixa, operação e resultado (D1), com
  atrasos históricos medidos como premissa.
- **RF-069-02** Cenários com choques de uma lista fechada e extensível por
  dado, combináveis e guardados (D2).
- **RF-069-03** Propagação em cascata pelas regras reais em modo de
  simulação, com o caminho do efeito visível (D3).
- **RF-069-04** Comparação base × cenários, com o que mais pesa no
  resultado e as ações sugeridas (D5).
- **RF-069-05** Cenário a partir de uma pergunta pelo assistente, com
  conferência das premissas (D6).
- **RF-069-06** Cenários recalculados periodicamente, com métricas para
  alertas e regras (D7).
- **RF-069-07** Moeda nos documentos de compra e de venda e cotações como
  valores da empresa com vigência (spec 065), quando ainda não existirem.

## Requisitos não funcionais
- **RNF-069-01 (escrita).** Simular não grava documentos nem títulos.
  Grava só a definição do cenário e, se a pessoa pedir, o resumo do
  resultado. O valor fica no orçamento de escrita da spec 063.
- **RNF-069-02 (desempenho).** Medidos na bateria, sobre a massa da
  simulação de uso (spec 067):
  - um cenário de 6 meses para uma empresa com 10 mil títulos abertos,
    2 mil pedidos em carteira e 500 ordens de produção fica pronto em até
    10 s;
  - mudar um único choque recalcula só o que depende dele, em até 3 s;
  - o cálculo roda fora do caminho das telas de operação e com limite de
    processos simultâneos.
- **RNF-069-03 (correção).** A projeção base de hoje para ontem confere com
  o realizado dentro de uma tolerância medida, e o desvio é mostrado. Um
  cenário sem choques é igual à base.
- **RNF-069-04 (segurança).** Escopo de dados e sigilo aplicados em todo
  resultado (D8). O assistente nunca monta um cenário com dados que quem
  pergunta não pode ver.

## Critérios de aceite
- **CA-069-01** Com o cenário "dólar +15% a partir do mês que vem" e
  "fornecedor X atrasa 10 dias", a tela mostra, em relação à base:
  - a nova menor posição de caixa e a data dela;
  - a margem por linha;
  - as entregas que atrasam.

  Cada número abre o caminho do efeito até os documentos de origem.
- **CA-069-02** Um cenário sem choques dá exatamente a base.
- **CA-069-03** Simular não muda nenhuma tabela de negócio (verificado pelo
  ensaio universal) e grava só o cenário.
- **CA-069-04** "E se o maior cliente pagar 5 dias depois?" no assistente
  mostra as premissas entendidas e, confirmadas, o efeito no caixa.
- **CA-069-05** Um vendedor que simula vê só a própria carteira e não vê o
  caixa da empresa.
- **CA-069-06** Um cenário vigiado cuja menor posição de caixa piora além
  do limite gera alerta com a comparação.
- **CA-069-07** O cenário de referência de RNF-069-02 fica pronto dentro do
  tempo na bateria.
