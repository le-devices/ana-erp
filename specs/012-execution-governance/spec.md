# 012 — Governança de execução (limites finos de recursos)

## Problema
Hoje os limites de execução são globais (tempo, memória, saída). Um ERP com
programas escritos pelos próprios clientes precisa de controle **granular**:
um relatório pesado pode ter mais tempo e memória; uma Função exposta à
internet deve ter limites curtos; um usuário não pode monopolizar o servidor;
o administrador precisa ver quanto cada programa realmente consome.

## Histórias
- **H1** Como administrador, defino tetos globais que nenhum programa ultrapassa.
- **H2** Como desenvolvedor, declaro limites de um programa (tempo de parede,
  CPU, memória, tempo por SQL, espera por trava, saída, linhas por consulta,
  execuções simultâneas) — dentro dos tetos.
- **H3** Como administrador, defino limites por papel e por grupo de acesso
  (ex.: usuários externos com prazos menores).
- **H4** Como administrador, limito cada usuário: execuções simultâneas e
  execuções por minuto.
- **H5** Como administrador, vejo CPU, memória máxima, tempo e nº de comandos
  SQL de cada execução, e os programas que mais consomem.

## Requisitos funcionais
- **RF-012-01** Limites suportados (todos opcionais por programa):
  | Chave | Significado | Unidade |
  |-------|-------------|---------|
  | `timeout_ms` | tempo de parede da execução | ms |
  | `cpu_ms` | tempo de CPU do processo Python | ms |
  | `memory_mb` | memória virtual do processo Python | MiB |
  | `sql_timeout_ms` | tempo máximo de cada comando SQL | ms |
  | `lock_timeout_ms` | espera máxima por travas | ms |
  | `output_kb` | saída máxima (texto, logs, tabelas) | KiB |
  | `max_rows` | linhas máximas devolvidas por consulta | linhas |
  | `max_sql` | comandos SQL por execução | comandos |
  | `max_concurrent` | execuções simultâneas do programa | execuções |
- **RF-012-02** Limite efetivo = mínimo entre: limite do programa (ou padrão
  global), limite do papel/grupos do usuário, teto global e o pedido da
  chamada (`timeout_ms` só pode reduzir). Nunca acima do teto.
- **RF-012-03** Tetos e padrões globais são parâmetros (spec 011): para cada
  chave, `default_<chave>` e `max_<chave>`.
- **RF-012-04** Limites por papel e por grupo: `ana_system.limit_profile`
  aplicado a papéis (`user`, `developer`, `admin`) e a grupos de acesso; se o
  usuário estiver em vários grupos, vale o **maior** limite dos grupos (grupos
  concedem), sempre limitado pelo teto.
- **RF-012-05** Por usuário: `user_max_concurrent` e `user_runs_per_minute`
  (parâmetros, com exceções por usuário). Excesso → `QUOTA_EXCEEDED` (HTTP 429).
- **RF-012-06** Estouros geram erros distintos: `TIMEOUT`, `CPU_LIMIT`,
  `MEMORY`, `OUTPUT_LIMIT` (saída truncada, execução segue), `ROW_LIMIT`,
  `SQL_LIMIT`, `PROGRAM_BUSY` (`max_concurrent`).
- **RF-012-07** Medição por execução, gravada na auditoria: tempo de parede,
  CPU (ms), memória máxima residente (KiB), nº de comandos SQL, linhas lidas,
  limites efetivos aplicados.
- **RF-012-08** Estúdio: seção **Limites** nas propriedades do programa
  (desenvolvedor edita dentro dos tetos; vê os efetivos); Administração:
  perfis de limite por papel/grupo, cotas por usuário e ranking de consumo
  (CPU, memória, tempo) por programa no período.
- **RF-012-09** Alterar limites de programa exige `developer`; reduzir tetos
  ou alterar perfis de limite exige `admin`; tudo registrado em `admin_log`.

## Requisitos não funcionais
- **RNF-012-01** (robustez) CPU e memória são impostas pelo sistema
  operacional (`RLIMIT_CPU`, `RLIMIT_AS`) no próprio processo da execução,
  ajustadas no início de cada execução (processos pré-aquecidos incluídos).
- **RNF-012-02** (performance) Cálculo do limite efetivo sem ida ao banco
  (cache de programas, perfis e parâmetros); contadores de concorrência em
  `atomics`/ETS.
- **RNF-012-03** (segurança) Nenhum caminho permite ultrapassar o teto — nem
  pela chamada, nem pelo programa, nem por grupo.

## Critérios de aceite
- **CA-012-01** Programa com `cpu_ms = 500` em laço de CPU termina com
  `CPU_LIMIT` em ~0,5 s de CPU; a auditoria registra a CPU usada.
- **CA-012-02** Programa com `memory_mb = 64` que aloca 200 MiB termina com
  `MEMORY`.
- **CA-012-03** `max_rows = 10` em consulta de 1000 linhas → `ROW_LIMIT`.
- **CA-012-04** `max_concurrent = 1`: segunda execução simultânea →
  `PROGRAM_BUSY`.
- **CA-012-05** Limite de programa acima do teto é recusado ao salvar; se o
  teto for reduzido depois, o limite efetivo passa a ser o teto.
- **CA-012-06** Usuário com `user_max_concurrent = 1` recebe `QUOTA_EXCEEDED`
  na segunda execução simultânea.
- **CA-012-07** Grupo com perfil de limite maior concede mais tempo ao membro,
  limitado pelo teto.
- **CA-012-08** Execução registra `cpu_ms`, `max_rss_kb` e `sql_count`.
