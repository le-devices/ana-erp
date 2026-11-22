# 051 — Automação por padrão

Situação: implementada (nov/2026), menos a auditoria por área (T-051-06, junto com a 050 fase 3) e as sugestões de sequência e de correção repetida (T-051-04b, sobre a spec 046): regras "quando… então…" ensaiadas antes de ligar e nunca em laço, central de automações, toda rotina automatizável, sugestões de agendar e de variante a partir do uso, exceções de esteira como tarefas que se concluem sozinhas.

## Problema
O ANA já automatiza muito: esteiras (spec 030), BPM (spec 039), agendamento
(spec 018), integrações com nova tentativa (spec 017), atendimento do pedido
por política (spec 041), conciliações (spec 038). Mas cada automação é
configurada num lugar, e o ERP ainda não **percebe** o que as pessoas fazem
repetidamente nem oferece automatizar. P19 pede que o repetitivo seja do ERP.

## Decisões
- **D1 — Central de automações.** Uma tela única lista tudo o que roda
  sozinho (agendamentos, esteiras, processos, regras, integrações, alertas,
  rotinas periódicas do produto): dono, último resultado, próxima execução,
  falhas com motivo; ligar, desligar, ensaiar e ver o histórico.
- **D2 — Regras "quando… então…" sem código.** Gatilho (evento de documento,
  mudança de situação, horário, limite de métrica, mensagem recebida) +
  condições (construtor de condições, spec 020) + ações de uma lista
  fechada (executar rotina com variante, mudar situação, criar tarefa no
  BPM, enviar e-mail ou aviso, chamar conector). Toda regra tem dono (P14),
  é ensaiada antes de ligar e fica na auditoria.
- **D3 — Sugestões a partir do uso.** O ERP observa padrões nas execuções
  (mesma rotina, mesmos parâmetros, mesma hora/dia; mesma sequência de
  rotinas; mesma correção manual repetida) e sugere: agendar, criar regra,
  criar variante, ajustar política. A pessoa aceita com um clique; recusada,
  a sugestão não volta.
- **D4 — Exceções, não rotina.** Toda decisão rotineira tem política
  configurável; só o que foge da política vira tarefa para uma pessoa, na
  caixa "Minhas tarefas" (spec 039), já com o contexto e as ações possíveis.
- **D5 — Auditoria de automação por área.** Cada área revista: o que ainda
  exige passo manual repetitivo vira automação, política ou sugestão.

## Requisitos funcionais
- **RF-051-01** Central de automações (D1) com filtros, situação e ações.
- **RF-051-02** Regras "quando… então…" (D2): gatilhos, condições, ações,
  ensaio, limite de disparos por período, dono e auditoria.
- **RF-051-03** Motor de sugestões (D3) com explicação ("você executou X com
  estes valores nas últimas 6 segundas às 8h") e aceitar/recusar.
- **RF-051-04** Toda rotina executável pode ser agendada, disparada por
  regra ou posta numa esteira sem programar (verificado por teste sobre o
  catálogo de rotinas).
- **RF-051-05** Exceções como tarefas (D4) com contexto e ações.
- **RF-051-06** Auditoria por área (D5) com relatório do que deixou de ser
  manual.

## Requisitos não funcionais
- **RNF-051-01** Regra mal configurada não entra em laço: limite de disparos
  e detecção de ciclo (regra que dispara a si mesma).
- **RNF-051-02** Análise de uso para sugestões roda em segundo plano, sobre
  agregados (spec 046), sem custo nas execuções.

## Critérios de aceite
- **CA-051-01** Regra "quando pedido acima de R$ 50 mil for criado, então
  criar tarefa de aprovação para o grupo Diretoria" funciona, é ensaiada
  antes e aparece na central com dono e histórico.
- **CA-051-02** Executar a mesma rotina com os mesmos parâmetros em 4 dias
  úteis seguidos no mesmo horário gera a sugestão de agendar; aceitar cria o
  agendamento com variante.
- **CA-051-03** Regra que dispara a si mesma é bloqueada com aviso.
- **CA-051-04** A central lista agendamentos, esteiras, processos, regras e
  alertas com última execução e falhas.
