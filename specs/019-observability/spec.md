# 019 — Observabilidade e dicas de otimização

## Problema
Quando algo fica lento ou falha, é preciso responder rápido: o que está
doente, desde quando, em qual programa, em qual linha, em qual SQL — e o que
fazer. O monitor atual (spec 011) mostra só o estado instantâneo.

## Histórias
- **H1** Como administrador, vejo a saúde de cada componente (núcleo, pools de
  banco, processos Python, PostgreSQL, disco, filas, agendador, integrações)
  com estado verde/amarelo/vermelho e histórico.
- **H2** Como desenvolvedor, abro uma execução e vejo a **linha do tempo**:
  cada SQL (texto, parâmetros mascarados, duração, linhas), chamadas
  aninhadas, chamadas remotas, saída, e o **stack trace completo** em caso de
  erro (quadros do programa e das bibliotecas ANA, com variáveis locais do
  quadro do erro).
- **H3** Como desenvolvedor, ligo o **perfilamento** de um programa e vejo onde
  o tempo é gasto (funções Python e SQL), por linha.
- **H4** Como administrador, recebo **dicas de otimização** priorizadas:
  consultas lentas sem índice, N+1 (mesma consulta repetida em laço), lotes
  que deveriam usar `sql_batch`, programas perto dos limites, timeouts
  recorrentes, pools saturados, índices não usados, tabelas inchadas.
- **H5** Como operador, integro com ferramentas externas (métricas no formato
  Prometheus, logs estruturados JSON, rastros OpenTelemetry).
- **H6** Como administrador, defino alertas (limiar, duração, destino) e vejo
  incidentes abertos.

## Requisitos funcionais
- **RF-019-01** Verificações de saúde por componente, periódicas, com estado,
  mensagem, latência e histórico de 30 dias; `GET /health` (resumo público) e
  `GET /api/admin/health` (detalhe).
- **RF-019-02** Métricas: execuções por programa/status, duração (histograma),
  CPU, memória, SQL por execução, erros por código, filas e pools, uso do
  PostgreSQL (conexões, cache hit, bloqueios, replicação), métricas do BEAM
  (memória, processos, filas de mensagens, reduções). Exposição em
  `/metrics` (formato Prometheus, autenticado) e armazenamento resumido para
  gráficos no Estúdio.
- **RF-019-03** Rastreamento de execução (`ana_system.execution_trace`):
  eventos com tempo relativo — `sql` (texto normalizado, parâmetros
  mascarados, duração, linhas), `call`, `remote`, `library_load`, `output`,
  `error` — amostragem configurável (sempre em erro e em execuções lentas;
  percentual nas demais) e retenção configurável.
- **RF-019-04** Stack trace detalhado em erros: todos os quadros de programas
  e bibliotecas ANA (arquivo, linha, função, código), com variáveis locais do
  quadro do erro (repr truncado, campos sensíveis mascarados); visível só para
  `developer`+ (chamadores externos continuam sem rastro, RF-003-04).
- **RF-019-05** Perfilamento sob demanda por programa/execução: tempo por
  função e por linha (amostragem estatística de baixa sobrecarga) e tempo em
  SQL × Python; resultado navegável no Estúdio (tabela e gráfico de chama).
- **RF-019-06** Consultas lentas: registro das que passam do limiar com
  `EXPLAIN` (sem executar de novo quando possível; `pg_stat_statements` quando
  disponível), plano resumido e destaque de varreduras sequenciais em tabelas
  grandes.
- **RF-019-07** Motor de dicas (`ana_advisor`) com regras e evidências:
  N+1 (mesma consulta ≥ N vezes por execução), consulta lenta com seq scan
  em coluna filtrada (sugere índice com DDL proposto), FK sem índice,
  programa com p95 > 80 % do limite, timeouts recorrentes, saída grande,
  pool com espera, índice não usado, tabela com muito espaço morto. Cada dica:
  severidade, impacto estimado, evidência (execuções/consultas), ação sugerida,
  dispensar/adiar.
- **RF-019-08** Alertas: regras sobre métricas/saúde (limiar, janela,
  severidade), destinos (e-mail, webhook, Estúdio), silenciamento e incidentes
  com início/fim.
- **RF-019-09** Logs estruturados (JSON) com correlação: `execution_id`,
  usuário, programa, requisição; consulta e filtro no Estúdio.
- **RF-019-10** Exportação OpenTelemetry (rastros e métricas) opcional por
  configuração.

## Requisitos não funcionais
- **RNF-019-01** (performance) Sobrecarga do rastreamento < 5 % no p95 com
  amostragem padrão; perfilamento desligado por padrão.
- **RNF-019-02** (segurança) Parâmetros SQL e variáveis com nomes sensíveis
  (`password`, `token`, `secret`, `cpf`…) mascarados; métricas e detalhes só
  para `admin`/`developer`.
- **RNF-019-03** (robustez) Observabilidade nunca derruba o negócio: buffers
  limitados, descarte com contagem quando sobrecarregado, gravação assíncrona.
- **RNF-019-04** Retenção e particionamento por tempo (traces, métricas,
  logs), com limpeza automática.

## Critérios de aceite
- **CA-019-01** Derrubar o banco deixa `database` vermelho em ≤ 10 s e abre
  incidente; voltar fecha o incidente.
- **CA-019-02** Execução com erro mostra stack trace com linha e variáveis
  locais do quadro do erro; chamada remota do mesmo erro não mostra.
- **CA-019-03** Programa que faz a mesma consulta 500 vezes em laço gera dica
  N+1 com sugestão de `sql_batch`/JOIN e a evidência.
- **CA-019-04** Consulta lenta por coluna sem índice gera dica com
  `CREATE INDEX` sugerido.
- **CA-019-05** Perfilamento mostra a função mais custosa de um programa de
  teste.
- **CA-019-06** `/metrics` exige autenticação e expõe as métricas de execução.
