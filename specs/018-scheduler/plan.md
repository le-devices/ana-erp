# 018 — Plano técnico: Agendamento de rotinas

## Dados (migração `009_scheduler.sql`, esquema `scheduler`)
Esquema interno: **sem** privilégios para `ana_exec`/`ana_read` (programas não
alteram agendas).

| Tabela | Conteúdo |
|--------|----------|
| `job` | `name` único, programa, `params` (com modelos de data), `run_as` (usuário técnico), `limits` pedidos (spec 012), `active`, `concurrency` (`skip`/`queue`/`parallel`), `max_parallel`, `missed` (`skip`/`run_once`/`run_all`), `max_catchup`, `retries`, `retry_backoff_s`, `on_exhausted` (`notify`/`pause`), `window_start`/`window_end`, `timezone`, `late_after_s`, `owner`, auditoria |
| `trigger` | `kind`: `cron` (`cron`), `interval` (`interval_s`), `once` (`fire_at`), `calendar` (`rule`: `last_business_day` \| `nth_business_day`, `nth`, `at_time`), `after_job` (`after_job_id`, `after_condition`, `result_param`); `business_days_only`, `starts_at`, `ends_at`, `next_at` (UTC, indexado), `last_at` |
| `holiday` | dia, descrição (dias úteis = seg–sex menos feriados) |
| `occurrence` | `job_id`, `trigger_id`, `scheduled_at` (UTC), `attempt`, `status` (`pending`/`running`/`success`/`error`/`skipped`/`cancelled`), `run_after`, `execution_id`, início/fim, `result`, `error`, `reason`; **`UNIQUE (job_id, scheduled_at, attempt)`** = reserva atômica |
| `notification` | `job_id`, `kind` (`failure`/`late`/`anomaly`/`paused`), mensagem, lida |

## Núcleo
- `ana_cron` (puro, testável): parser de 5 campos (listas, faixas, passos,
  `*`, nomes `jan..dec`/`sun..sat`, semântica OU entre dia-do-mês e
  dia-da-semana quando ambos restritos), `next/2` sobre data-hora **local**
  (ingênua); regras de calendário `last_business_day`/`nth_business_day` e
  `business_day/2` com lista de feriados.
- **Fuso e horário de verão**: o cálculo é feito em hora local do fuso da
  rotina; a conversão local→UTC usa o PostgreSQL
  (`timestamp AT TIME ZONE tz`), que tem a base de fusos. Hora inexistente
  (avanço do relógio) é deslocada para frente; hora repetida (retrocesso) é
  convertida uma única vez — nunca duplica, nunca some.
- `ana_scheduler` (gen_server, um por nó):
  - **Liderança**: conexão dedicada com `pg_try_advisory_lock` de sessão; se o
    nó cai, a conexão fecha e outro nó assume no próximo ciclo (≤ 5 s).
  - Ciclo de 1 s no líder: (1) materializa gatilhos vencidos (`next_at <=
    now()`) em ocorrências `pending` via `INSERT … ON CONFLICT DO NOTHING`,
    aplicando a política de perdidas; (2) avança `next_at`; (3) dispara
    ocorrências `pending` com `run_after <= now()` respeitando concorrência e
    janela; (4) gera avisos de atraso.
  - Cada disparo roda num processo monitorado que chama
    `ana_execution:run/4` (síncrono, origem `internal`, como `run_as`, com os
    limites pedidos) e grava o resultado na ocorrência; falha → nova
    ocorrência `attempt+1` com `run_after = agora + backoff·2^(n-1)`;
    esgotadas → aviso e, se `on_exhausted = pause`, desativa a rotina.
  - Ao fim, dispara dependentes (`after_job`) conforme a condição, passando o
    resultado em `result_param`.
  - Ao assumir a liderança, ocorrências `running` órfãs são reconciliadas com
    `ana_system.execution` (terminadas → status real; sem registro → `error`
    "interrompida").
- Modelos de parâmetros: `{{today}}`, `{{yesterday}}`, `{{now}}`,
  `{{month_start}}`, `{{last_month_start}}`, `{{last_month_end}}` no fuso da
  rotina, substituídos em valores texto.
- Duração anômala: > 3× a média das últimas 20 execuções com sucesso (mínimo
  5 amostras) gera aviso `anomaly`.

## HTTP (`/api/scheduler/*`)
`GET/POST jobs`, `GET/PUT/DELETE jobs/:id`, `POST jobs/:id/{run,pause,resume,skip-next}`,
`GET jobs/:id/preview?n=10`, `GET jobs/:id/occurrences`, `GET/PUT/DELETE holidays[/:day]`,
`GET notifications`, `POST notifications/:id/read`. Criar/alterar exige
`developer`; `run_as` diferente do próprio usuário exige `admin` (RF-018-09);
tudo em `admin_log`.

## Estúdio (spec 020: coisas relacionadas juntas)
- Desenvolvimento → programa → aba **Agendamentos**: rotinas daquele programa,
  criação rápida, próximas ocorrências e histórico.
- Administração → Operação do sistema → **Agendamento**: todas as rotinas,
  feriados e avisos.
- Início: card **Avisos** com notificações das rotinas do usuário.

## Notificações (RF-018-08)
Nesta entrega: avisos no Estúdio e chamada opcional a um programa de
notificação (`notify_program`) que recebe o aviso — o envio por e-mail/webhook
passa a ser feito por esse programa via conector quando a spec 017 existir.

## Teste de cluster
`tests/cluster/`: sobe um segundo nó do núcleo apontando para o mesmo banco
(senhas de papéis fixas) e verifica que cada ocorrência roda uma única vez
(CA-018-01); o mesmo arranjo testa a distribuição Erlang (`ana_rpc:call/3` por
`erpc`, T-003-06).
