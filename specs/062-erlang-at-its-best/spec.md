# 062 — Erlang ao máximo (sem pagar em desempenho nem robustez)

Situação: especificada (nov/2026).

## Problema
O núcleo do ANA é Erlang/OTP (P3), mas usa a plataforma de forma
conservadora. Hoje:
- a árvore de supervisão é **plana**: cerca de 17 processos sob um único
  supervisor, com limite de reinício compartilhado — uma falha repetida num
  subsistema pode esgotar o limite e derrubar os vizinhos;
- várias partes **consultam o banco em ciclos**: a fila de integração a cada
  segundo em todos os nós, o motor de processos (BPM) e as esteiras em
  ciclos no líder, a saúde a cada 10 s;
- o Estúdio **não recebe nada empurrado**: tarefas, avisos, situação de
  execuções e painéis só mudam quando a tela pergunta de novo;
- não há publicação de eventos entre nós (a invalidação de cache usa
  `LISTEN`/`NOTIFY` do PostgreSQL, o que está certo, mas é o único canal);
- a introspecção do próprio núcleo (processos, filas de mensagens, memória,
  reduções) não aparece para o administrador.
Ao mesmo tempo, já há bons usos: caches em ETS e `persistent_term`,
contadores atômicos, disjuntores, limites por cliente, troca de código sem
parada (P16). P20 pede ir além **só onde ficar mais rápido, mais robusto ou
mais vivo** — e provar com medição.

## Decisões
- **D1 — Supervisão por subsistema.** A árvore passa a ter supervisores por
  área (execução e Python; banco e cache; integração; agendamento, processos
  e esteiras; observabilidade e verificações; API pública; arquivos), cada
  um com estratégia e limites próprios; processos dinâmicos (um por conector,
  um por fluxo de dados de bancada, um por sessão ao vivo) ficam sob
  supervisores dinâmicos. A falha repetida de um subsistema não reinicia os
  outros.
- **D2 — Eventos no lugar de ciclos.** Um barramento de eventos do núcleo
  (grupos de processos do OTP — `pg` — no nó e entre nós) publica fatos:
  mensagem na fila de integração, tarefa criada, execução terminada, aviso,
  incidente, documento alterado. Quem consome acorda pelo evento; o ciclo
  periódico fica só como rede de segurança, mais espaçado (o evento pode se
  perder numa queda; o banco continua sendo a verdade, P4). Entre nós, o
  `NOTIFY` do PostgreSQL continua como ponte quando a distribuição Erlang não
  está ligada.
- **D3 — Ao vivo no Estúdio.** Conexão de eventos do servidor para o
  navegador (SSE sobre o cowboy; WebSocket só se precisar de duas vias), por
  usuário, filtrada pelas permissões dele: "Minhas tarefas", avisos do sino,
  situação de execuções e esteiras, painel inicial (spec 048) e painel do
  chão de fábrica (spec 054) se atualizam sozinhos. Cada conexão é um
  processo leve, com limite por usuário e por nó, e cai sem afetar nada.
- **D4 — Isolamento por unidade.** Um processo por conector de integração
  (fila, limite por minuto, disjuntor e tentativas dele), por cliente da API
  pública nos pontos de estado e por fluxo de dados de equipamento: um
  conector lento ou travado não atrasa os outros (hoje um lote compartilhado
  pode esperar o mais lento).
- **D5 — Temporizadores do próprio Erlang** para prazos curtos e frequentes
  (tempo de espera de tarefas BPM, novas tentativas, silêncios de alerta,
  expiração de acessos emergenciais), carregados do banco ao subir e
  reprogramados na troca de líder — o banco guarda o prazo; o processo só o
  vigia.
- **D6 — Introspecção na Administração.** Tela "Núcleo" (observabilidade,
  spec 019): processos que mais consomem (memória, reduções, fila de
  mensagens), supervisores e reinícios recentes, uso de ETS, agendadores,
  distribuição entre nós — só leitura, com alerta (T-019-08b) para fila de
  mensagens crescendo ou reinícios em sequência.
- **D7 — Contrapressão explícita.** Toda fila em memória tem limite; quem
  produz mais rápido do que se consome recebe "ocupado" (como a capacidade
  pública da API) em vez de crescer a memória sem fim.
- **D8 — Onde NÃO usar.** Dados de negócio continuam no PostgreSQL (nada de
  Mnesia para isso); estado que precisa sobreviver a queda vai para o banco;
  código nativo (NIF) só com justificativa e teste de caos; distribuição
  Erlang continua opcional (P9) — tudo funciona com um nó só.
- **D9 — Medir sempre.** Cada tarefa traz a referência antes (latência p95,
  vazão, memória, CPU, tempo de recuperação nos testes de caos) e a
  comparação depois; regressão impede a integração.

## Revisão das funcionalidades já implementadas (P20)
Cada subsistema existente é revisto com D1–D9 (tarefas da fase 3):
- execução de programas e processos Python (specs 002, 012, 022);
- API pública e chamadas remotas (specs 003, 010);
- integração: fila de saída/entrada, conectores, webhooks, e-mail (specs 017, 044);
- agendamento, esteiras e processos BPM (specs 018, 030, 039);
- observabilidade, alertas e verificações (specs 019, 033);
- arquivos e uploads (spec 016);
- cache, permissões e sessões (specs 009, 011);
- alta disponibilidade e drenagem (spec 023).

## Requisitos funcionais
- **RF-062-01** Árvore de supervisão por subsistema (D1).
- **RF-062-02** Barramento de eventos no nó e entre nós (D2), com a fila de
  integração e o motor de processos acordando por evento.
- **RF-062-03** Eventos ao vivo no Estúdio (D3) para tarefas, avisos,
  execuções, esteiras e painéis, com filtro por permissão.
- **RF-062-04** Um processo por conector e por fluxo de equipamento (D4).
- **RF-062-05** Temporizadores do Erlang para prazos curtos (D5).
- **RF-062-06** Tela "Núcleo" com introspecção e alertas (D6).
- **RF-062-07** Limites em toda fila em memória (D7).
- **RF-062-08** Revisão dos subsistemas existentes com relatório (fase 3).

## Requisitos não funcionais
- **RNF-062-01** Nenhuma regressão: p95 das rotas e das execuções, vazão da
  API pública, memória e tempo de recuperação nos testes de caos iguais ou
  melhores (D9).
- **RNF-062-02** Mensagem na fila de integração começa a ser entregue em
  menos de 100 ms (hoje até 1 s); tarefa BPM aparece em "Minhas tarefas" sem
  recarregar em menos de 1 s.
- **RNF-062-03** 10 mil conexões ao vivo por nó com memória previsível.
- **RNF-062-04** Funciona com um nó só e com a distribuição Erlang
  desligada (P9).

## Critérios de aceite
- **CA-062-01** Um subsistema que falha em sequência esgota só o próprio
  supervisor; os demais continuam atendendo (teste de caos).
- **CA-062-02** Um conector que não responde não atrasa a entrega pelos
  outros conectores.
- **CA-062-03** Uma tarefa criada por um processo aparece aberta na tela de
  "Minhas tarefas" de outro usuário, sem recarregar, em menos de 1 s.
- **CA-062-04** A tela "Núcleo" mostra o processo com a maior fila de
  mensagens, e uma fila crescendo dispara alerta.
- **CA-062-05** Comparação antes/depois anexada a cada tarefa, sem
  regressão.
