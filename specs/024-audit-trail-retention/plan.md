# 024 — Plano técnico

## Dados (migração 011_audit_trail.sql)
- `ana_system.access_event` (bigserial; `at`, `username` sem FK — tentativas
  sem usuário válido também são gravadas —, `auth`, `api_key_id`, `ip`,
  `method`, `path`, `status`, `duration_ms`, `node`, `detail`). BRIN em `at`,
  btree `(username, at DESC)`.
- `ana_system.execution`: `client_ip`, `api_key_id`, `node`,
  `internal_trace`, `payload_purged_at`.
- `ana_system.retention_day (day date PK, node, claimed_at)`: o nó que
  inserir o dia (`ON CONFLICT DO NOTHING`) executa o expurgo — uma vez por
  dia no cluster, como as ocorrências do agendamento.

## Núcleo
- `ana_access_log` (gen_server): `record/1` faz `cast`; buffer em lista,
  `flush` a cada 1 s ou 500 itens com um único `INSERT … SELECT * FROM
  unnest(...)`; limite de 50 000 com contagem de descartes.
- Coleta HTTP: `cowboy_metrics_h` na cadeia de stream handlers, com
  `metrics_callback` filtrando `/api` e `/rpc`. O handler identifica o
  usuário em `ana_http:authenticate/1` e envia
  `cowboy_req:cast({set_options, #{metrics_user_data => …}})`; o login e o
  console SQL acrescentam `username`/`detail` do mesmo jeito. Duração vem de
  `req_start`/`resp_end` (monotônico).
- O mapa do usuário autenticado ganha `trace => #{ip, auth, key_id}`;
  `ana_execution` grava `client_ip`/`api_key_id`/`node`. `/api/me` remove
  `trace`.
- Falhas internas em `ana_execution` (`catch Class:Reason:Stack`) guardam
  `internal_trace` formatado (até 16 KiB).
- `ana_rpc:call/3` com nome de usuário (distribuição): registra acesso com
  `auth = node` e `ip = node(group_leader())`.
- `ana_retention` (gen_server): verifica a cada 60 s; na hora configurada
  (fuso `ANA_TIMEZONE`, consultado no banco), reivindica o dia e roda
  `purge/1` via `ana_task:run(<<"retention.purge">>, system_user(), …)`.
  Cada categoria: `DELETE … WHERE ctid = ANY(ARRAY(SELECT ctid … LIMIT 5000))`
  em laço, com 50 ms entre lotes; conteúdo das execuções:
  `UPDATE … SET params = NULL, result = NULL, output = NULL,
  error = error - 'trace', internal_trace = NULL, payload_purged_at = now()`
  em lotes. `overview/0` usa `reltuples`, `pg_total_relation_size` e o mais
  antigo pelo índice de tempo.
- Parâmetros (`ana_settings`): `retention_*_days` e `retention_hour`, com os
  mínimos da spec como `Min`.

## HTTP (admin)
- `GET /api/admin/audit/access`, `GET /api/admin/audit/trail?username=`,
  `GET /api/admin/audit/executions/:id`, `GET /api/admin/retention`,
  `POST /api/admin/retention/purge`.

## Interface
- Auditoria: abas Execuções (clique → detalhe), Requisições, Logins,
  Tarefas internas, Alterações, e Trilha (por usuário).
- Ficha do usuário: botão "Ver trilha".
- Nova seção "Retenção" em Operação do sistema: tabela com prazo editável,
  volume, mais antigo; último expurgo; "Expurgar agora".
