# 025 — Plano técnico

- **Analítico (migração 012):** `analytics.refresh_state (id = 1, signature
  bigint, refreshed_at)`; `analytics.refresh(force boolean DEFAULT false)`
  calcula a assinatura `sum(n_tup_ins + n_tup_upd + n_tup_del)` de
  `pg_stat_user_tables` das tabelas de origem; igual à última e `force =
  false` → `'unchanged'` sem escrita. `track_counts = off` → recalcula.
  `ana_analytics:refresh/2` passa `force` quando a origem é o Estúdio.
- **Acessos particionados (migração 011, ainda não aplicada):**
  `access_event PARTITION BY RANGE (at)`, PK `(id, at)`, partição `DEFAULT`.
  `ana_retention` cria `access_event_YYYYMMDD` de hoje a +7 dias na partida e
  a cada dia; no expurgo, `DROP TABLE` das partições cujo limite superior é
  anterior ao corte e lotes de `DELETE` só na partição padrão.
- **Lote assíncrono:** `ana_access_log` grava em transação com
  `SET LOCAL synchronous_commit = off`.
- **Execução:** `audit_start` agendado para 1 s depois (imediato em
  depuração/assíncrona); `audit_end` é UPSERT, então cobre os dois casos.
- **HOT:** remover o índice `execution_cpu_idx (started_at, cpu_ms)` (o
  ranking por período usa `execution_started_idx`); `fillfactor = 90` em
  `execution`, `scheduler.occurrence`, `scheduler.trigger`, `api_key`.
- **Chave de API:** `UPDATE … WHERE last_used_at < now() - interval '1 minute'`.
- **Compose:** parâmetros do PostgreSQL e `logging` com `max-size`/`max-file`.
