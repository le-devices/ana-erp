# 026 — Gráficos

Situação: implementada

## Problema
Tabelas e indicadores mostram números, mas tendência, composição e
comparação se leem melhor em gráfico. Programas do produto e do cliente
precisam desenhar gráficos ricos com uma linha de código, e as telas de
administração (consumo, saúde, desempenho do SQL) também.

## Requisitos funcionais
- **RF-026-01** `ana.chart(spec)` em qualquer programa: tipos `line`,
  `area`, `column` (agrupado), `stacked` (colunas empilhadas), `bar`
  (horizontal, ranking) e `donut` (parte do todo, até 6 fatias);
  `x` (categorias ou datas), `series` (`name`, `values`), `unit`/`format`
  (`number`, `money`, `percent`, `hours`), `title`, `subtitle`.
- **RF-026-02** Leitura sem depender de cor: legenda sempre que houver 2+
  séries, rótulos diretos seletivos (fim das linhas, ponta das barras), visão
  em tabela em todo gráfico (com exportação CSV), dica ao passar o mouse ou
  focar (linha guia nas séries temporais; por marca nas barras).
- **RF-026-03** Paleta categórica fixa de 8 cores, validada para daltonismo
  nos temas claro e escuro (ordem fixa; cor segue a série, nunca a posição);
  mais de 8 séries são agrupadas em "Outros". Nunca dois eixos verticais.
- **RF-026-04** Valores negativos (ex.: resultado acumulado) com linha de base
  no zero; números no formato brasileiro.
- **RF-026-05** O gráfico acompanha o tamanho do quadro (redimensionável) e o
  tema claro/escuro.
- **RF-026-06** Gráficos nas telas: viabilidade (mês a mês), portfólio,
  alocação, painel de vendas, consumo e monitor da administração.

## Requisitos não funcionais
- **RNF-026-01** Sem dependências externas; SVG desenhado no navegador com
  CSP estrita (cores por classe, nunca atributo `style`).
- **RNF-026-02** Rótulos vindos dos dados entram só como texto (nunca HTML).
- **RNF-026-03** 5 mil pontos por gráfico desenham em menos de 200 ms.

## Critérios de aceite
- **CA-026-01** Um programa com `ana.chart` de linha com 3 séries mostra o
  gráfico, a legenda, os rótulos no fim das linhas e a tabela equivalente.
- **CA-026-02** Série com mais de 8 entradas é agrupada em "Outros".
- **CA-026-03** Especificação inválida (tamanhos diferentes, valor não
  numérico, tipo desconhecido) é recusada com mensagem clara.
- **CA-026-04** A viabilidade de um projeto mostra o mês a mês em gráfico.
