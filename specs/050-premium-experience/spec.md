# 050 — Experiência premium (padrão de UX e auditoria de todas as telas)

Situação: implementada (nov/2026): fases 1, 2 e 3 — todas as telas alcançáveis verificadas por um rastreador sem linha de base, regras verificadas nos programas e auditoria por área (audit.md). Ficaram, medidas: próximo passo em 108 rotinas que gravam (T-050-17), desfazer (T-050-18), valores padrão pelo contexto (T-050-19) e formulários lentos com muitos dados (T-050-20). Fases 2 e 3: ver plan.md.

Decisões de implementação (fase 1): o verificador (`tests/studio/ux_check.mjs`) roda em cada tela que o
teste do Estúdio alcança — campo e controle sem nome acessível, imagem sem texto alternativo, lista vazia
sem ação, texto técnico fora do Desenvolvimento e da Administração, id repetido — e compara com a linha de
base `tests/studio/ux_baseline.json` (35 violações que já existiam, corrigidas na fase 3); violação nova
faz a bateria falhar. Listas vazias ganharam `emptyAction`. O catálogo de erros (`errors.js`) traduz os
códigos técnicos em "o que houve e o que fazer"; desenvolvedores e administradores também veem o código. O
Estúdio mede abertura de telas, chamadas e travamentos (`perf.js`) e envia em lote; o núcleo agrega em
memória e grava um histograma por dia, tela e tipo uma vez por minuto (`ana_ui_perf`, P15); tela com p95
acima de 1 s vira o apontamento `ui_slow_screen`; tela "Desempenho das telas" na Administração. Página
"Padrões" no Desenvolvimento com as regras e exemplos vivos.

## Problema
O ANA já tem uma linguagem visual (spec 029), arquitetura da informação e
padrões de produtividade (spec 020). Mas cada tela foi feita numa época, e a
qualidade varia: algumas têm atalhos, valores padrão, simulação e mensagens
claras; outras não. Para ser vendido como produto premium (P18), a
experiência precisa ser **igual e excelente em todo lugar** — e continuar
assim a cada tela nova, sem depender de lembrar.

## Decisões
- **D1 — Um padrão escrito e verificável.** Catálogo de componentes e
  padrões (tabela de trabalho, ficha, formulário de rotina, painel, gráfico,
  diálogo, aviso, estado vazio, carregamento, erro) com regras de uso, e um
  **verificador automático** que roda nos testes do Estúdio e falha a
  bateria quando uma tela quebra o padrão (P18 vira teste, não opinião).
- **D2 — Orçamento de desempenho.** Ação → retorno visível ≤ 100 ms;
  tela aberta ≤ 1 s (p95) com os dados usuais; nenhuma tarefa da interface
  acima de 50 ms; listas de 10 mil linhas roláveis (virtualização). Medido
  pelo próprio Estúdio e enviado à observabilidade (spec 019).
- **D3 — Nada sem próximo passo.** Toda tela de resultado mostra a próxima
  ação do processo (spec 020); todo estado vazio explica e oferece o botão
  que o preenche ("Nenhum pedido ainda — Criar pedido"); toda mensagem de
  erro tem o que houve, por quê e como resolver, sem código técnico.
- **D4 — Paleta de comandos e teclado em tudo.** Ctrl+K abre a paleta:
  rotinas, documentos, cadastros, ações da tela atual e "perguntar ao
  assistente" (spec 052). Toda ação frequente tem atalho visível; F8 salva,
  F9 simula (já existentes) em todo formulário.
- **D5 — Desfazer e ensaiar.** O que grava pode ser ensaiado (spec 056); o
  que é reversível mostra "desfazer" por alguns segundos (cancelamento por
  documento, P17); o irreversível pede confirmação dizendo a consequência.
- **D6 — Menos digitação.** Valores padrão pelo contexto (cliente → condição
  de pagamento, depósito, vendedor; último uso; variante — spec 045),
  preenchimento por CNPJ (spec 043), colar planilha em grades, leitura de
  código de barras e QR pela câmera no celular.
- **D7 — Primeira impressão.** Implantação guiada (spec 061), dados de
  demonstração com um clique, tour curto por área, ajuda contextual em cada
  campo (o rótulo e a dica vêm da declaração do programa).
- **D8 — Auditoria de todas as áreas.** Cada área existente é revista contra
  o padrão (tarefas por área abaixo), com lista do que falta e correção; o
  verificador impede regressão depois.

## Requisitos funcionais
- **RF-050-01** Catálogo de padrões e componentes documentado, com exemplos
  vivos no Estúdio (página "Padrões", só para desenvolvedores).
- **RF-050-02** Verificador automático de telas: nome acessível em todo
  campo, contraste, foco visível, estado vazio com ação, erro com orientação,
  atalhos declarados, sem texto técnico para usuário final, sem rolagem
  horizontal no celular, tempo de abertura dentro do orçamento.
- **RF-050-03** Medição de desempenho da interface por tela (abertura, ação,
  tarefas longas) enviada à observabilidade; tela fora do orçamento vira
  apontamento nas Verificações (spec 033).
- **RF-050-04** Paleta de comandos global (D4) e atalhos por tela, com tela de
  ajuda "?" listando os atalhos.
- **RF-050-05** Desfazer padronizado para ações reversíveis (D5) e
  confirmação com consequência para as irreversíveis.
- **RF-050-06** Valores padrão por contexto e último uso (D6), declarados no
  programa (`default_from`) e respeitando permissões.
- **RF-050-07** Mensagens: catálogo de códigos de erro com texto ao usuário,
  causa provável e ação sugerida; nenhum código técnico na tela de operação.
- **RF-050-08** Leitura de código de barras/QR pela câmera em campos de item,
  lote, número de série e documento (celular e computador com câmera).
- **RF-050-09** Auditoria por área (D8) com relatório do que foi corrigido.

## Requisitos não funcionais
- **RNF-050-01** Orçamento de desempenho (D2) verificado na bateria.
- **RNF-050-02** WCAG 2.2 AA em todo o Estúdio e no portal.
- **RNF-050-03** Nenhuma facilidade contorna permissão, auditoria ou
  validação (P10, P18).

## Critérios de aceite
- **CA-050-01** Uma tela nova sem nome acessível num campo, ou sem ação no
  estado vazio, faz a bateria do Estúdio falhar com a tela e o motivo.
- **CA-050-02** Ctrl+K encontra uma rotina, um pedido pelo número e um
  cliente pelo CNPJ, e executa a ação escolhida.
- **CA-050-03** Cancelar um pedido mostra "desfazer" e desfazer restaura o
  estado anterior por documento.
- **CA-050-04** Erro de negócio mostra o que houve e como resolver; nenhum
  "SQL", pilha ou código interno aparece para o usuário de operação.
- **CA-050-05** Todas as áreas auditadas, com o verificador verde.
