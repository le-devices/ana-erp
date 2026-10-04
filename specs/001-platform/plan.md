# 001 — Plano técnico: Plataforma

## Pilha
- Erlang/OTP 27, rebar3, release com ERTS embutido.
- `epgsql` (driver PostgreSQL), `cowboy` (HTTP). JSON via módulo `json` nativo
  do OTP 27 (sem dependência extra).
- PostgreSQL 16.

## Árvore de supervisão
```
ana_sup (one_for_one)
├── ana_db            pool de conexões (gen_server)
├── ana_execution_sup  simple_one_for_one — uma criança por execução (spec 002)
├── ana_analytics     atualização periódica de visões (spec 007)
└── cowboy listener   ana_http (iniciado em ana_app)
```
Migrações e semeadura rodam em `ana_app:start/2` antes de abrir o HTTP.

## Configuração (variáveis de ambiente)
| Variável | Padrão |
|----------|--------|
| `ANA_DB_HOST` / `ANA_DB_PORT` | `localhost` / `5432` |
| `ANA_DB_NAME` / `ANA_DB_USER` / `ANA_DB_PASSWORD` | `ana` / `ana` / `ana` |
| `ANA_DB_POOL` | `10` |
| `ANA_HTTP_PORT` | `8080` |
| `ANA_ADMIN_PASSWORD` | `admin` |
| `ANA_SESSION_HOURS` | `12` |
| `ANA_PYTHON` | `python3` |

## Módulos
| Módulo | Responsabilidade | Requisitos |
|--------|------------------|------------|
| `ana_config` | leitura de env com padrões | RF-001-02 |
| `ana_db` | pool; `query/3`, `transaction/1`, conversão de tipos ↔ JSON | RF-001-02 |
| `ana_migrate` | aplica `priv/migrations/NNN_*.sql` em ordem; tabela `ana_system.migration` | RF-001-01 |
| `ana_security` | PBKDF2, sessões, papéis, admin inicial | RF-001-03..06, 08 |
| `ana_http` | rotas cowboy, utilidades de resposta JSON | RF-001-05..07, RNF-001-03 |

## Pool de conexões
`ana_db` guarda N conexões livres e uma fila de espera. `com_conexao(Fun)`
faz checkout, monitora o processo cliente (se morrer, a conexão é reciclada com
`ROLLBACK`) e devolve ao final. Conexões quebradas são substituídas.

## Tipos PostgreSQL ↔ JSON
- Parâmetros: antes de executar, o statement é preparado (`parse`) e os valores
  JSON são coagidos ao tipo esperado (date, timestamp, numeric, json/jsonb,
  uuid, bool, int, float, text).
- Resultados: date → `"AAAA-MM-DD"`, timestamp → ISO-8601, numeric → número,
  json/jsonb → objeto decodificado, null → `null`.

## Sessões
Tabela `ana_system.session` **UNLOGGED** (dado efêmero, escrita rápida, sem WAL —
se o banco cair, usuários apenas fazem login de novo). Token = 32 bytes
aleatórios em base64url; guardado como SHA-256.

## Riscos
- Pool esgotado por execuções em depuração longas → pool configurável e
  depuração em conexão dedicada (spec 004).

## Segurança (RF-001-09/10, RNF-001-04..06)
- Papéis PostgreSQL criados pela migração e habilitados para LOGIN na partida
  (`ana_app:configurar_papeis/0`), com senha conhecida só pelo núcleo
  (`ANA_DB_EXEC_PASSWORD`/`ANA_DB_READ_PASSWORD` ou aleatória por partida):
  - `ana_exec`: USAGE/DML nos esquemas de negócio, **sem acesso** a
    `ana_system`. Pool dedicado `ana_db_exec` atende os programas (spec 002).
  - `ana_read`: somente SELECT; conexão efêmera do console SQL, com
    `BEGIN READ ONLY`.
  - **Decisão:** conexões *autenticadas* como o papel, e não `SET ROLE`, porque
    `RESET ROLE` dentro do SQL do programa devolveria os privilégios do dono.
  - Limites no próprio papel: `statement_timeout`,
    `idle_in_transaction_session_timeout`, `CONNECTION LIMIT`.
- O núcleo não usa superusuário: o papel `ana` é dono do banco com
  `CREATEROLE` (cria apenas os papéis que administra).
- Bloqueio de força bruta em ETS (`ana_attempts`): contador por login com
  janela de 5 min.
- `ana_http_security` (middleware cowboy) injeta cabeçalhos de segurança em toda
  resposta.
- `crypto:hash_equals/2` para comparação de hashes.

## Robustez (RNF-001-07, 08)
- `ana_db:aguardar_banco/0` com recuo 0,5 s → 8 s, limite 60 s.
- Checkout monitora o cliente; no `'DOWN'` o pool executa `ROLLBACK` e
  `RESET ALL` fora do processo do pool; se falhar, descarta e abre nova conexão.
- Reconexão com um único temporizador e recuo exponencial (0,5 s → 30 s).
- Checkout com prazo: ao desistir, conexões emprestadas tardiamente são
  recolhidas (sem vazamento).

## Performance (RNF-001-09)
- ETS `ana_stmt_cache` com chave `{ConexaoPid, Sql}` → `#statement{}`. Entradas
  da conexão são descartadas quando ela é substituída.
