# 021 — Consultoria: gestão de projetos de clientes de ponta a ponta

Situação: implementada (portal do cliente depende da spec 016)

## Problema
O nicho de consultoria (engenharia, P&D, software, gestão) vive de projetos de
clientes. A spec 008 cobre horas, despesas, marcos e faturamento, mas falta a
**gestão do trabalho**: enxergar o fluxo completo do projeto, planejar horas
por fase e por pessoa, acompanhar o andamento contra o plano, controlar
mudanças de escopo e manter o cliente informado — tudo num fluxo coerente.

## Histórias
- **H1** Como gerente, monto a estrutura do projeto em **fases** e
  **atividades** (com entregáveis, dependências e datas planejadas) a partir de
  um modelo de projeto ou do zero.
- **H2** Como gerente, **aloco horas** por fase/atividade e por pessoa (ou perfil)
  ao longo das semanas, vendo a capacidade de cada um (spec 014) e conflitos
  com outros projetos.
- **H3** Como gerente, vejo o **fluxo do trabalho** num quadro (a fazer,
  em andamento, em revisão, concluído) e numa linha do tempo (Gantt) com o
  caminho crítico.
- **H4** Como consultor, vejo minhas atividades da semana, aponto horas
  direto nelas (spec 008) e atualizo o andamento (% concluído, observações).
- **H5** Como gerente, faço a **conferência do andamento**: planejado ×
  realizado em horas, custo e prazo por fase; % concluído físico × % das horas
  consumidas; previsão no término; alertas de desvio.
- **H6** Como gerente, registro **mudanças de escopo** (pedido do cliente →
  estimativa → aprovação → nova linha de base) sem perder o histórico.
- **H7** Como gerente, gero o **relatório de status** periódico (andamento,
  marcos, riscos, horas, próximos passos) e o publico ao cliente no portal
  (spec 016).
- **H8** Como cliente, acompanho no portal o andamento, aprovo entregáveis e
  mudanças de escopo.
- **H9** Como diretor, vejo o **portfólio**: todos os projetos com saúde
  (prazo, custo, escopo), margem e alocação da equipe.

## Requisitos funcionais
- **RF-021-01** Estrutura analítica: fases → atividades (sub-níveis
  opcionais), com responsável, perfil, horas planejadas, datas planejadas,
  dependências (término→início com folga), entregável e critério de aceite.
  Tarefas de 008 passam a ser as atividades (compatível).
- **RF-021-02** Modelos de projeto (fases/atividades/horas típicas) por tipo
  de serviço, reutilizáveis por cliente (P13).
- **RF-021-03** Alocação: horas por pessoa ou perfil × atividade × semana;
  verificação de capacidade (calendário de 014: jornada, férias, feriados) e de
  sobrealocação entre projetos; sugestão de redistribuição.
- **RF-021-03a** Alocação de pessoal às tarefas: o gerente atribui pessoas
  (ou um perfil, quando ainda não sabe quem) a cada atividade, com horas por
  semana ou distribuindo um total automaticamente pelas semanas úteis entre
  início e término da atividade (proporcional aos dias úteis). Alocar quem
  não é da equipe o inclui na equipe do projeto com seu perfil. Uma alocação
  por perfil pode ser trocada por uma pessoa (mantendo as horas). A
  atividade mostra horas planejadas × alocadas × apontadas por pessoa. O
  quadro de alocação (pessoas × semanas, todos os projetos) destaca
  sobrealocação e capacidade livre; cada pessoa vê as próprias alocações em
  "Minha semana".
- **RF-021-04** Fluxo: estados das atividades (`todo`, `doing`, `review`,
  `done`, `blocked`) com quadro de colunas e linha do tempo (Gantt) com
  caminho crítico recalculado a cada mudança.
- **RF-021-05** Andamento: % concluído informado por atividade (ou calculado
  por entregáveis aceitos); indicadores por fase e projeto: horas planejadas ×
  realizadas, custo, prazo, valor agregado (VP, VA, CR → IDP, IDC) e
  estimativa no término.
- **RF-021-06** Linha de base: o plano aprovado é congelado; replanejamentos
  geram nova linha de base versionada; comparação entre linhas de base.
- **RF-021-07** Mudança de escopo: registro, estimativa de horas/valor/prazo,
  aprovação (interna e do cliente), efeito no orçamento e no faturamento
  (marcos/horas adicionais).
- **RF-021-08** Riscos e pendências: registro com probabilidade, impacto,
  dono, plano de ação e prazo.
- **RF-021-09** Relatório de status periódico gerado automaticamente
  (agendável, spec 018) e publicado no portal do cliente (spec 016).
- **RF-021-10** Visões por papel no fluxo da spec 020: **Minha semana**
  (consultor: atividades, apontamento em um clique), **Projeto** (gerente:
  estrutura, alocação, quadro, andamento, mudanças, riscos, faturamento — tudo
  em abas do mesmo projeto), **Portfólio** (diretor).
- **RF-021-11** Fluxo guiado do projeto (RF-020-11): proposta → aprovação →
  planejamento (linha de base) → execução → medições/marcos → faturamento →
  encerramento, com a etapa atual destacada e a próxima ação sugerida.
- **RF-021-12** Lucro a partir da alocação: o custo projetado do projeto
  vem das horas alocadas × custo-hora de cada pessoa; horas alocadas só a um
  perfil, ou planejadas sem alocação, usam o custo padrão do perfil (ou a
  média do custo das pessoas desse perfil). Durante a execução, o lucro
  previsto no término = realizado (apontamentos, despesas, faturado) +
  alocações futuras e horas planejadas restantes. Painel, portfólio e
  andamento mostram o lucro previsto a quem gerencia o projeto.
- **RF-021-13** Projeção de viabilidade (inclusive na proposta): receita
  conforme a cobrança (por hora: horas faturáveis × valor-hora do perfil no
  projeto; preço fechado: orçamento; misto: marcos + horas faturáveis),
  impostos sobre serviço, custo de pessoal, despesas previstas (únicas ou
  mensais — mensais crescem quando o prazo cresce), rateio de despesas
  gerais (% sobre o custo de pessoal), lucro, margem e distribuição mês a
  mês (receita, custo, resultado acumulado e o mês em que o resultado
  acumulado fica positivo).
- **RF-021-14a** Toda projeção mostra sempre, lado a lado, os cenários
  **base** (o plano), **otimista** e **pessimista**. As variações de cada um
  (horas, custo, valor-hora, atraso) vêm da política da empresa (padrão:
  otimista −10 % horas; pessimista +20 % horas, +10 % custo, +4 semanas) e
  podem ser ajustadas por projeto. A classificação de viabilidade usa o
  cenário base; se o pessimista der prejuízo, a projeção e a aprovação do
  plano avisam.
- **RF-021-14** Cenários "e se": variação de valor-hora (%), de horas (%), de
  custo (%) e atraso (semanas), simulados na hora e salvos para comparação
  lado a lado com o plano; o gerente corrige valores-hora, alocação,
  prazos e despesas e vê o efeito imediatamente.
- **RF-021-15** Política de margem (parâmetros da empresa): margem alvo,
  margem mínima e % de despesas gerais. A projeção classifica o projeto
  (viável, atenção, inviável). Aprovar o plano abaixo da margem mínima exige
  justificativa explícita, registrada na linha de base, que também guarda
  receita, custo e lucro projetados para comparação posterior.

## Requisitos não funcionais
- **RNF-021-01** (performance) Quadro e Gantt de projeto com 2 mil
  atividades em < 1 s; portfólio de 500 projetos em < 2 s (agregados em
  visões materializadas atualizadas por evento).
- **RNF-021-02** (segurança) Cliente no portal vê apenas seus projetos e o que
  for marcado como visível; custo e margem nunca aparecem para o cliente
  (RNF-008-02).
- **RNF-021-03** (robustez) Recalcular caminho crítico e indicadores é
  idempotente e não bloqueia apontamentos.

## Critérios de aceite
- **CA-021-01** Projeto criado a partir de modelo traz fases, atividades e
  horas planejadas; aprovar o plano cria a linha de base 1.
- **CA-021-02** Alocar 50 h numa semana para uma pessoa com 40 h de
  capacidade gera alerta de sobrealocação, considerando outros projetos.
- **CA-021-02a** Distribuir 60 h numa atividade de 3 semanas úteis aloca 20 h
  por semana à pessoa; alocar alguém de fora da equipe o inclui na equipe;
  trocar a alocação de um perfil por uma pessoa mantém as horas; a atividade
  mostra planejado × alocado × apontado por pessoa.
- **CA-021-03** Atividade atrasada no caminho crítico desloca a data prevista
  do projeto; fora do caminho crítico, consome folga.
- **CA-021-04** Fase com 60 % das horas consumidas e 40 % concluída mostra IDC
  < 1 e alerta de desvio.
- **CA-021-05** Mudança de escopo aprovada pelo cliente aumenta orçamento,
  cria marco adicional e nova linha de base, mantendo a anterior consultável.
- **CA-021-06** Consultor aponta horas a partir de "Minha semana" sem navegar
  por outras telas.
- **CA-021-08** Alocar uma pessoa de custo-hora maior numa atividade reduz o
  lucro projetado do projeto na mesma proporção (horas × diferença de custo).
- **CA-021-09** Projeto em proposta mostra receita, custo, lucro, margem e
  distribuição mensal nos cenários base, otimista e pessimista (pessimista
  com lucro menor que o base, otimista maior); um cenário com valor-hora +10 % e atraso de 4 semanas
  aparece lado a lado com o plano, com o efeito das despesas mensais.
- **CA-021-10** Aprovar plano com margem projetada abaixo da mínima é recusado
  (`LOW_MARGIN`) sem justificativa; com justificativa, a linha de base guarda
  a justificativa e os valores projetados.
- **CA-021-07** Relatório de status agendado aparece no portal do cliente sem
  custos.
