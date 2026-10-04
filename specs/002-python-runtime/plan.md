# 002 — Plano técnico: Runtime Python

## Visão geral
```
 HTTP / RPC / ana.call
          │
   ana_execution (gen_server, 1 por execução, temporário)
          │  checkout de conexão ─► ana_db_exec (login ana_exec)
          │                         BEGIN; SET LOCAL statement_timeout/lock_timeout
          │  obtém worker ─────────► ana_py_pool (pré-aquecidos)
          ▼
   Port {packet,4}  ◄──JSON──►  python3 -I -S ana_runtime.py
                                 (env vazio, rlimits, sem credenciais)
```
O worker Python **nunca** fala com o banco: pede ao processo `ana_execution`,
que executa na conexão da Unidade de Trabalho e responde.

## Protocolo (JSON, quadros com prefixo de 4 bytes big-endian)
Núcleo → Python:
| `type` | campos |
|--------|--------|
| `run` | `program`, `version`, `source`, `params`, `context`, `debug`, `breakpoints`, `stop_on_entry` |
| `inspect` | `source` |
| `response` | `id`, `ok` (bool), `value` \| `error` — resposta a um pedido do Python |
| `debug` | `action`, ... (spec 004) |
| `cancel` | — |

Python → núcleo:
| `type` | campos |
|--------|--------|
| `ready` | `pid` (enviado na partida; worker entra no pool) |
| `request` | `id`, `op` (`sql`, `sql_batch`, `call`, `remote`, `library_source`, `savepoint`), `args` |
| `output` | `kind` (`text`, `log`, `table`), `data` |
| `pause` | estado do depurador (spec 004) |
| `inspection` | `ok`, `params`, `docs`, `has_main`, `error` |
| `end` | `ok`, `result` \| `error` {`code`, `message`, `line`, `trace`, `data`} |

Pedidos são síncronos do ponto de vista do Python (envia `request`, bloqueia
até `response` com o mesmo `id`).

## Isolamento (RNF-002-01)
- Port aberto com `{env, [...]}` zerando variáveis herdadas (lista explícita
  contendo só `PATH`, `LANG`, `PYTHONDONTWRITEBYTECODE` e os limites `ANA_PY_*`),
  `{cd, "/tmp"}` e `python3 -I` (modo isolado: ignora `PYTHON*` e site do usuário).
- `ana_runtime.py` aplica `resource.setrlimit` na partida: AS, CPU, NOFILE 64,
  FSIZE 16 MiB, NPROC 0 quando possível; e substitui o fd 1 para que nada além
  do protocolo use o stdout real.
- No contêiner, o núcleo roda como usuário não-root `ana`.

## Unidade de Trabalho (RF-002-08)
`ana_execution` faz checkout no pool `ana_db_exec`, `BEGIN`,
`SET LOCAL statement_timeout` e `lock_timeout`. Operações demoradas (SQL,
chamadas remotas) rodam num processo auxiliar ligado: o `ana_execution` segue
atendendo prazos e comandos e, no estouro, faz `epgsql:cancel/1` e ROLLBACK.
`ana.call` cria `SAVEPOINT`, um novo worker Python e reentra no laço de
mensagens **no mesmo processo e conexão** (pilha de workers); no fim, `RELEASE`
(sucesso) ou `ROLLBACK TO` (falha, entregue ao chamador como `ana.Error`).
Profundidade máxima 16.

## Auditoria (RF-002-09, P11)
INSERT em `ana_system.execution` com status `running` antes de começar e
UPDATE no fim — ambos em **outra conexão** (fora da Unidade de Trabalho).

## Pool pré-aquecido (RNF-002-07)
`ana_py_pool` (gen_server) mantém N ports que já enviaram `ready`. `checkout/0`
entrega um e transfere a posse do port (`port_connect`) ao chamador;
dispara reposição. Se vazio, cria um na hora. Workers que morrem no pool são
repostos.

## Contrapressão (RNF-002-05)
Contador atômico (`atomics`) de execuções ativas; `ana_execution:run/4`
recusa com `OVERLOAD` acima do limite.

## Cache de fontes (RNF-002-08)
ETS `ana_program_cache` `Name → metadata + source`, invalidado na gravação e
por LISTEN/NOTIFY no canal `ana_program` (outros nós).

## Tipos Python ↔ JSON
Resultados SQL chegam compactos (`columns` com `name`/`type`, `rows` como
listas) e o runtime converte `numeric` → `Decimal`, `date`/`timestamp[tz]` →
`date`/`datetime`. Na saída, `Decimal` vira texto exato.

## Esquema
`ana_system.program`, `ana_system.program_version`, `ana_system.execution`
(migração `001_system.sql`).
