# 012 — Plano técnico: Governança de execução

## Dados (migração `007_execution_governance.sql`)
- `ana_system.program.limits jsonb` (chaves de RF-012-01).
- `ana_system.limit_profile(target_kind role|group, target, limits jsonb)`.
- `ana_system.user_quota(username, max_concurrent, runs_per_minute)` (exceções).
- `ana_system.execution` + `cpu_ms`, `max_rss_kb`, `sql_count`, `rows_read`,
  `limits jsonb`.

## Núcleo
- `ana_limits:effective(Program, User, Requested) -> Limits` — combina padrões,
  perfis (ETS), tetos (`ana_settings`) e pedido (RF-012-02).
- `ana_settings` ganha `default_*`/`max_*` para cada chave.
- `ana_quota`: contadores por usuário (concorrência em ETS com
  `update_counter`; janela de 1 min por balde) e por programa (`max_concurrent`).
- `ana_execution`: envia `limits` na mensagem `run`; conta SQL e linhas
  (`max_sql`, `max_rows` aplicados no núcleo, antes de responder ao Python);
  grava a medição recebida no `end`.

## Runtime Python
- Ao receber `run`, aplica `RLIMIT_CPU` = CPU já usada + `cpu_ms` e
  `RLIMIT_AS` = `memory_mb` (redução sempre permitida).
- Tratador de `SIGXCPU` lança exceção → `end` com `CPU_LIMIT`.
- No fim, `resource.getrusage` → `cpu_ms`, `max_rss_kb` no `end`.

## Estúdio
- Propriedades → Limites (campos por chave, mostrando teto e efetivo).
- Administração → Limites: perfis por papel/grupo, cotas, ranking de consumo.
