# 019 — Plano técnico

Princípios: observabilidade nunca derruba o negócio (buffers limitados,
gravação assíncrona, descarte contado) e grava pouco (P15): agregados em
memória gravados por minuto, só mudanças de estado, amostragem de rastros.

## Dados (migração 017_observability.sql)
- `execution_trace` (por execução amostrada): eventos SQL (texto normalizado,
  duração µs, linhas, linha do programa), chamadas, e o perfil quando pedido.
  Amostragem: sempre com erro ou execução lenta (`trace_slow_ms`), e
  `trace_sample_pct` % das demais. Particionada por mês? Não: volume baixo por
  amostragem; expurgo pela retenção (spec 024, categoria nova).
- `sql_stat` (por comando normalizado — hash): chamadas, tempo total/máx.,
  linhas, programas, primeira/última vez, último plano (`EXPLAIN
  (GENERIC_PLAN, FORMAT JSON)`, sem executar) e o resumo do plano.
- `advice` (dicas): regra + alvo (único), severidade, título, detalhe,
  evidência, sugestão, situação (aberta, dispensada até, resolvida), datas.
- `health_event` (só mudanças de estado) e `incident` (abre no vermelho,
  fecha no verde).
- `table_growth` (uma linha por tabela por dia) para projeções.
- `program.lint` (apontamentos estáticos, recalculados ao salvar).

## Medição do SQL (ana_execution)
- O runtime envia a linha do programa que chamou (`line`) em cada pedido SQL.
- A execução mede cada comando (do pedido à resposta), conta repetições por
  comando (N+1) e, ao terminar: envia os agregados ao `ana_sql_stats`
  (cast) e, se amostrada, grava o rastro.
- `ana_sql_stats` (gen_server): agrega em memória e grava a cada 60 s
  (um UPSERT por comando distinto); comando acima de `slow_sql_ms` agenda um
  `EXPLAIN (GENERIC_PLAN)` (no máximo um por comando por hora), com conexão
  `ana_exec` (mesmas permissões do programa).
- Análise do plano: varreduras sequenciais (tabela, linhas estimadas, filtro
  e colunas do filtro), ordenações, custo; sugere índice com as colunas do
  filtro.

## Análise estática (runtime Python, na inspeção)
AST: chamadas `ana.sql*` — literal de texto analisado por regras; f-string
ou concatenação → SQL dinâmico; chamada dentro de `for`/`while`/compreensão
→ N+1 provável. Resultado com linha, regra, severidade, mensagem e sugestão.

## Dicas (ana_advisor)
Roda a cada 15 min no nó líder do agendador (uma vez no cluster) e sob
demanda. Regras: N+1 observado, varredura sequencial lenta (índice
sugerido), crescimento (projeção 90/180 dias × varredura completa), análise
estática dos programas, FK sem índice, índice não usado, tabela com muito
espaço morto, programa perto do limite de tempo (p95), prazos estourados
recorrentes. Dica que deixa de valer é marcada resolvida.

## Saúde e incidentes (ana_health)
A cada 10 s: banco (latência), pools (espera), Python, liderança do
agendador, buffer de acessos (descartes), disjuntores abertos. Mudanças viram
`health_event`; vermelho abre incidente (e chama `ANA_ALERT_WEBHOOK`, se
definido); verde fecha.

## Métricas
`/metrics` (formato Prometheus; sessão de admin/desenvolvedor ou chave de
robô) com contadores do ETS (execuções por programa/situação, duração,
SQL), pools, Python, BEAM. Amostras a cada 5 min em `metric_sample` para os
gráficos do Estúdio.

## Stack trace e perfil (runtime)
- Erro: quadros dos programas/bibliotecas (programa, linha, função, código)
  e variáveis do quadro do erro (repr truncado, nomes sensíveis mascarados);
  só para desenvolvedor+.
- Perfil sob demanda (`profile: true`, desenvolvedor): `cProfile` restrito a
  programas/bibliotecas + tempo esperando SQL; vai no rastro.

## Logs
`ANA_LOG_FORMAT=json`: formatador JSON com `execution_id`, programa e
usuário nos metadados do processo. OpenTelemetry fica para depois.

## Telas
Administração → Operação do sistema: **Saúde** (componentes, incidentes,
histórico), **Desempenho do SQL** (gráfico + tabela, plano, sugestão) e
**Dicas**. Detalhe da execução: linha do tempo do SQL, quadros e variáveis,
perfil. Programa (Desenvolvimento) → aba **Desempenho**: apontamentos
estáticos, comandos do programa, último perfil.
