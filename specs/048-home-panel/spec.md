# 048 — Painel inicial

Situação: especificada (nov/2026).

## Problema
O início do Estúdio já tem blocos (favoritas, categorias pessoais e da
empresa, recentes, minhas tarefas — specs 020, 029, 039), mas os blocos são
só atalhos: não mostram números, não se organizam por perfil da empresa e não
há uma busca única. Quem abre o sistema quer ver de relance "o que precisa da
minha atenção" e chegar a qualquer rotina em dois toques.

## Decisões
- **D1 — Blocos com indicador ao vivo.** Um bloco pode mostrar um número,
  uma situação (ok/atenção/crítico, com ícone e texto) e uma linha curta,
  alimentados por um **programa indicador** leve (marcado como indicador, só
  leitura, tempo máximo curto), com cache por usuário e atualização periódica
  configurável (mínimo 1 min). Clicar abre a rotina, já com uma variante
  (spec 045) se definida.
- **D2 — Grupos publicados por perfil.** A empresa monta **espaços** (ex.:
  "Financeiro", "Engenharia", "Campo") com grupos de blocos e os publica para
  grupos de acesso (spec 011); cada usuário vê os espaços dos seus grupos,
  mais o seu espaço pessoal. Um bloco nunca aparece se o usuário não pode
  executar a rotina.
- **D3 — Personalização.** O usuário reordena, esconde e muda o tamanho
  (pequeno, médio, largo) dos blocos, cria grupos pessoais e restaura o
  padrão da empresa; guardado no servidor (spec 020, AnaPrefs).
- **D4 — Contadores e avisos.** Tarefas pendentes (BPM), aprovações,
  avisos do sistema e notificações aparecem como contadores nos blocos e num
  centro de avisos único.
- **D5 — Busca global.** Uma caixa no topo procura rotinas (nome, descrição,
  categoria), documentos por número (pedido, fatura, OS — spec 035) e
  cadastros (parceiro, item, CNPJ — spec 040), respeitando permissões;
  atalho de teclado.
- **D6 — Acessível e leve.** Navegável por teclado e leitor de tela (spec
  020); funciona no celular; um bloco que falha mostra "indisponível" sem
  derrubar o painel.

## Requisitos funcionais
- **RF-048-01** Programas indicadores (D1): declaração no programa, limites
  próprios, cache por usuário com prazo, atualização automática e manual.
- **RF-048-02** Espaços e grupos da empresa por grupo de acesso (D2), com
  editor para administradores e pré-visualização "como o usuário X vê".
- **RF-048-03** Personalização pessoal (D3) com restauração do padrão.
- **RF-048-04** Contadores e centro de avisos (D4).
- **RF-048-05** Busca global (D5).
- **RF-048-06** Bloco abre a rotina com variante (spec 045) ou um documento.
- **RF-048-07** Os blocos atuais (favoritas, categorias, recentes, tarefas)
  continuam como grupos do espaço pessoal — nada se perde na mudança.

## Requisitos não funcionais
- **RNF-048-01** Painel com 30 blocos e 10 indicadores abre em < 1 s
  (indicadores em paralelo, cache); indicador lento não atrasa os outros.
- **RNF-048-02** Indicadores executam como o usuário (P14) e com o escopo de
  dados dele (spec 009): dois usuários veem números diferentes quando o
  escopo difere.
- **RNF-048-03** Busca global responde em < 300 ms com 1 milhão de cadastros.

## Critérios de aceite
- **CA-048-01** Bloco "Pedidos com falta" mostra o número certo e muda após um
  pedido novo, no próximo ciclo de atualização.
- **CA-048-02** Espaço "Financeiro" publicado para o grupo financeiro aparece
  para seus membros e não para os demais; bloco de rotina sem permissão não
  aparece.
- **CA-048-03** O usuário esconde e reordena blocos, sai e volta: continua
  igual; "restaurar padrão" volta ao da empresa.
- **CA-048-04** Buscar um CNPJ encontra o parceiro; buscar o número de uma
  fatura abre o documento.
- **CA-048-05** Indicador que falha mostra "indisponível" e o resto do painel
  funciona.

## Experiência e automação (P18, P19)
- Blocos sugeridos pelo uso (spec 051): rotinas e variantes usadas com
  frequência viram bloco proposto.
- Entrada do assistente (spec 052) e da paleta de comandos (spec 050) no
  topo do painel.
- Painel em modo TV (tela cheia, atualização automática) para chão de fábrica
  e equipes (spec 054).
