# 029 — Linguagem visual "Linha ANA" (reforma da interface)

## Problema
A interface funciona, mas parece uma ferramenta técnica: barra superior com
abas e textos soltos, rotinas com parâmetros e resultado lado a lado, saídas
em fonte monoespaçada, tabelas cruas. O dono do produto pediu uma reforma
inspirada no estilo analítico de ERPs corporativos modernos (referência:
páginas analíticas com cabeçalho de indicadores, gráficos em cartões e
tabela de itens), **sem copiar propriedade intelectual de terceiros**.

## Princípios
- Identidade própria: nome, logotipo, ícones e paleta do ANA; fonte do
  sistema operacional; nenhum ícone, fonte, tema ou marca de terceiros.
- Mesmo conteúdo, nova apresentação: nenhuma regra de negócio muda; os
  programas continuam emitindo `metrics`, `chart`, `table`… (spec 021/026).
- Densidade de ERP (muita informação por tela) com respiro e hierarquia.
- Acessível: contraste AA, foco visível, teclado (F8, F3, Ctrl+Enter),
  modo escuro próprio (não inversão automática).
- Sem dependências externas e compatível com a CSP estrita (spec 020).

## Requisitos
- **RF-029-01** Barra superior compacta: avatar com iniciais (menu do
  usuário: trocar senha, sair), voltar, marca e as **áreas como abas sempre
  visíveis** (a ativa sublinhada; troca com um clique); à direita busca
  (Ir para…) e avisos. No celular, as abas formam uma linha rolável sob a
  barra. (Revisado a pedido do dono do produto: o menu ▾ isolado no centro
  era lento e pouco intuitivo.)
- **RF-029-02** Página de rotina analítica: faixa de cabeçalho com módulo,
  título, favorito e filtros em linha (Executar à direita); depois de
  executar, os filtros viram um resumo com "Alterar". Resultado em largura
  total, abaixo.
- **RF-029-03** Indicadores (`metrics`) como chips com rótulo, valor grande e
  borda de estado (positivo, atenção, crítico, neutro).
- **RF-029-04** Gráficos em cartões com título e subtítulo; gráficos
  consecutivos lado a lado (grade responsiva).
- **RF-029-05** Tabelas em cartão: cabeçalho "Título (N)" com barra de
  ferramentas (exportar), cabeçalho de colunas fixo, números alinhados,
  linhas com destaque ao passar o mouse e seta nas linhas navegáveis.
- **RF-029-06** Início em blocos (favoritas, recentes) e últimas execuções
  em cartão de tabela.
- **RF-029-07** Ícones próprios em SVG (traço simples), sem fonte de ícones.
- **RF-029-08** Tokens de cor, espaçamento, raio e sombra em variáveis CSS,
  com tema claro e escuro.

## Critérios de aceite
- **CA-029-01** Nenhum teste de tela (smoke) quebra; nenhum erro de
  JavaScript; CSP sem violações.
- **CA-029-02** Rotina executada mostra indicadores, gráficos e tabelas no
  novo arranjo (captura de tela conferida em claro e escuro).
- **CA-029-03** Em 390 px de largura não há rolagem horizontal da página.
