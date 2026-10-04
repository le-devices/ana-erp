# 023 — Plano técnico

## Saúde: vida × prontidão (RF-023-01)
- `GET /health/live` → 200 enquanto o nó estiver de pé (o orquestrador só
  reinicia o contêiner se isto falhar).
- `GET /health/ready` → 200 só se: não está drenando, banco responde, os
  pools têm conexão, há Python pronto ou aquecendo, e o esquema é compatível
  (ver migrações). Caso contrário 503 com o motivo de cada verificação.
- `/health` continua como antes (compatível).
- O balanceador (HAProxy no ambiente de caos) usa `/health/ready`.

## Desligamento gracioso (RF-023-02)
`ana_app:prep_stop/1` (chamado pelo OTP ao receber SIGTERM):
1. marca drenagem (`persistent_term`): prontidão → 503 e novas execuções
   recusadas com `DRAINING` (HTTP 503);
2. espera `ANA_DRAIN_DELAY_MS` (padrão 2 s) para o balanceador perceber;
3. espera as execuções em curso terminarem, até `ANA_DRAIN_TIMEOUT_MS`
   (padrão 25 s);
4. suspende o listener HTTP e encerra.
O compose dá `stop_grace_period: 40s` ao contêiner do núcleo.

## Migrações compatíveis (RF-023-03)
- Regra (documentada no README e na constituição): expandir → migrar →
  contrair. Uma versão nova só adiciona (tabelas, colunas com padrão,
  índices); remoções e renomeações vão para uma versão seguinte, quando
  nenhum nó antigo roda mais.
- Migração que quebra a versão anterior declara `-- ana:breaking` na
  primeira linha.
- Na partida e na prontidão, o nó compara as migrações aplicadas com as que
  conhece: desconhecidas sem `breaking` → aviso (nó antigo durante rolling,
  continua pronto); desconhecida `breaking` → não pronto
  (`SCHEMA_INCOMPATIBLE`).

## Execuções interrompidas (RF-023-04)
- Na partida, o nó marca como `error`/`INTERRUPTED` as execuções `running`
  registradas por ele mesmo (não sobrevivem a um reinício).
- Periodicamente, `running` de qualquer nó há mais de 2× o teto de tempo →
  `INTERRUPTED` (nó que não voltou).
- O chamador síncrono de um nó que caiu recebe erro de conexão do
  balanceador (nunca fica pendurado); dentro de um nó vivo, a queda do
  processo da execução já devolve `INTERNAL` (spec 002).

## Banco em alta disponibilidade (RF-023-05)
- `ANA_DB_HOST` aceita uma lista (`pg1,pg2`). `ana_db:connect/2` tenta os
  endereços, começando pelo último que funcionou, e só aceita o primário
  (`pg_is_in_recovery() = false`) para núcleo e programas. Ao cair o
  primário, as conexões morrem, o pool reconecta com recuo e encontra a
  réplica promovida — sem reiniciar o núcleo.
- `ANA_DB_READ_HOSTS` (opcional): réplicas para o console SQL (consultas e
  relatórios de leitura); sem elas, o console usa o primário.
- Pool sem nenhuma conexão e banco fora → `checkout` falha na hora
  (`DB_UNAVAILABLE`, HTTP 503) em vez de esperar 15 s (CA-023-02).
- Todas as conexões (migração, papéis, LISTEN, liderança do agendador,
  console) passam por `ana_db:connect/2`.

## Cópias de segurança (RF-023-06)
- `docker-compose.backup.yml` liga `archive_mode` com cópia do WAL para um
  volume de arquivo; `scripts/backup.sh` faz a cópia base
  (`pg_basebackup`); `scripts/restore-test.sh` restaura a última cópia base
  num contêiner temporário até um instante (`recovery_target_time`) e
  verifica o banco restaurado.
- P15: o arquivamento de WAL grava mais; fica desligado no ambiente de
  desenvolvimento e é obrigatório em produção (documentado).

## Disjuntores e filas (RF-023-07)
- `ana_breaker`: por sistema remoto, N falhas seguidas (5) abrem o disjuntor
  por um intervalo (30 s) — chamadas falham na hora com
  `REMOTE_UNAVAILABLE`; depois, uma chamada de teste (meio aberto) decide.
- Filas já limitadas: admissão global (503), cotas (429), buffer de acessos,
  pool de Python e de conexões com espera limitada.

## Suíte de caos (RNF-023-03)
`tests/chaos/run.sh` sobe dois nós e um HAProxy (`docker-compose.chaos.yml`)
e roda `tests/chaos/test_chaos.py`: CA-023-01..06 e o teste de restauração.
