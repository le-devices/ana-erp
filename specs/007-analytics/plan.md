# 007 — Plano técnico: Camada Analítica

- Migração `004_analytics.sql`: visões materializadas + índices únicos;
  bloco `DO` que verifica `pg_available_extensions` por `citus` e cria a
  tabela fato colunar ou comum; função `analytics.refresh()` com
  `pg_try_advisory_xact_lock(hashtext('ana.analytics'))` retornando
  `'atualizado'` ou `'ja_em_andamento'`.
- `ana_analytics` (gen_server): temporizador periódico; guarda
  `last_refresh`; chamado também pelo endpoint.
- Imagem do banco: `citusdata/citus` (PostgreSQL 16) por padrão. O script de
  inicialização (superusuário) cria `citus` no banco `ana`; a migração 004 só
  verifica a extensão (`IF NOT EXISTS`, sem exigir superusuário) e cria a
  tabela fato `USING columnar`.
- Memória: parâmetros `ANA_PG_SHARED_BUFFERS`, `ANA_PG_EFFECTIVE_CACHE`,
  `ANA_PG_WORK_MEM` no compose; `shared_preload_libraries = citus,pg_prewarm`
  com `pg_prewarm.autoprewarm = on`.
