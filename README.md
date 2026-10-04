# ANA ERP

ERP com núcleo em **Erlang/OTP**, dados em **PostgreSQL** (com armazenamento
**colunar** para análise) e regras de negócio em **Python** — guardadas,
versionadas, executadas e **depuradas dentro do próprio ERP**, e chamáveis
remotamente por JSON-RPC. Pensado como **produto licenciável** para muitos
clientes.

Desenvolvido com **Spec Driven Development**: tudo começa em
[`specs/`](specs/README.md). Código em inglês; telas e documentação em português.

```
┌────────── Navegador: Início · Operação · Desenvolvimento · Administração ──────────┐
└───────────────────────────────────────┬─────────────────────────────────────────────┘
                                        │ HTTP (cowboy) · JSON-RPC 2.0 · nó Erlang
┌───────────────────────────────────────▼─────────────────────────────────────────────┐
│ Núcleo Erlang/OTP supervisionado                                                    │
│  ana_execution: 1 processo por execução = 1 transação (Unidade de Trabalho)         │
│  limites efetivos (tempo, CPU, memória, SQL, linhas, concorrência, cotas)           │
│  pools: ana_db (dono) · ana_db_exec (login ana_exec, sem acesso ao interno)         │
└──────────────┬──────────────────────────────────────┬──────────────────────────────┘
               │ protocolo JSON {packet,4}            │
   processos Python isolados e pré-aquecidos    PostgreSQL 16 + Citus (colunar),
   (sem credenciais, rlimits por execução)      pg_prewarm, visões materializadas
```

## Subir

Requer Docker.

```bash
docker compose up -d --build
```

Abra <http://localhost:8080> e entre com `admin` / `admin`. O ambiente vem com
dados de demonstração (`ANA_DEMO=true`): comércio e o caso de P&D em
eletrônica/firmware (projeto `PRJ-001`). Em produção, defina `ANA_DEMO=false`,
`ANA_ADMIN_PASSWORD`, `ANA_DB_PASSWORD`, `POSTGRES_PASSWORD` e `ANA_TIMEZONE`.

## Áreas da interface (spec 020)

| Área | Para quem | O que tem |
|------|-----------|-----------|
| **Início** | todos | favoritos, rotinas recentes, minhas últimas execuções |
| **Operação** | todos | rotinas agrupadas por módulo (Cadastros, Vendas, Estoque, Projetos, Financeiro…), cada uma com formulário, resultado e histórico na mesma tela |
| **Desenvolvimento** | `developer`+ | programa com abas Código (editor + executar/depurar), Propriedades e limites, Versões, Execuções, Agendamentos; Dados (catálogo + console SQL) |
| **Administração** | `admin` | Pessoas e acesso (usuários, grupos, limites e cotas); Sistema (empresa, parâmetros, contas padrão, comandos, sistemas remotos); Operação do sistema (agendamento, monitor, consumo, auditoria) |

A barra **Ir para…** abre rotinas por comando (`hello`, `balance`, `logtime`),
programas, tabelas e seções administrativas. O endereço (`#/ops/projects/…`)
pode ser favoritado e compartilhado.

## Escrevendo um programa

```python
"""Total vendido por cliente no período."""

from ana_lib.util.format import money          # Biblioteca guardada no ERP

PARAMS = {                                      # validado antes de executar
    "start": {"type": "date", "required": True},
    "customer": {"type": "int"},
}


def main(start, customer=None):
    rows = ana.sql(
        "SELECT c.name, sum(o.total) AS total FROM sales.sales_order o "
        "JOIN base.party c ON c.id = o.customer_id "
        "WHERE o.order_date >= $1 AND ($2::int IS NULL OR c.id = $2) GROUP BY c.name",
        start, customer)
    ana.table([{**r, "total": money(r["total"])} for r in rows], title="Vendas")
    if not rows:
        raise ana.Error("NO_SALES", "nenhuma venda no período")   # desfaz tudo
    return rows
```

| API `ana` | |
|-----------|---|
| `sql`, `sql_one`, `sql_value`, `sql_exec`, `sql_batch` | SQL parametrizado (`$1…`), resultados tipados (`Decimal`, `date`…) |
| `call(program, **p)` | outro programa, mesma transação, isolado por savepoint |
| `parallel`, `map`, `spawn`/`gather` | partes em paralelo (cada uma com processo, transação, limites e auditoria próprios), resultados na ordem; modo atômico (tudo ou nada, two-phase commit) e instantâneo compartilhado |
| `remote(system, function, **p)` | programa exposto de um sistema remoto cadastrado |
| `savepoint()` | `with`: falha no bloco desfaz só o bloco |
| `log`, `table`, `print` | saída na tela e na auditoria |
| `metrics`, `board`, `gantt`, `tabs`, `actions` | indicadores, quadro, linha do tempo, abas e ações (próximo passo, formulário em linha) |
| `context` | usuário, papel, execução, versão, origem |
| `Error(code, message, data)` | erro de negócio estruturado |

Toda execução é **uma Unidade de Trabalho**: sucesso → COMMIT; erro, prazo
estourado ou parada → ROLLBACK. Depuração sempre desfaz, salvo se marcado
"confirmar gravações".

## Módulos de negócio entregues

- **Cadastros**: partes (clientes/fornecedores), itens (`goods` com estoque e
  `service` sem estoque), listagem `products`.
- **Estoque, Vendas, Financeiro**: pedido → faturamento atômico (baixa,
  título, partidas dobradas), balancete; contas parametrizáveis.
- **Projetos (P&D)**: perfis e valor-hora, colaboradores e custo-hora
  (confidencial), projetos com tarefas e equipe, apontamento com limite diário,
  aprovação que congela valores, despesas e materiais de protótipo (com baixa
  de estoque), marcos, fatura de serviço com imposto retido, cancelamento com
  estorno, painel orçado × realizado e extrato para o cliente.
- **Analítico**: visões materializadas e tabela fato **colunar**.

## Consultoria: projetos de clientes (spec 021)

Tudo de um projeto numa tela com abas (`proj PRJ-001` na barra Ir para):
visão geral com o **fluxo guiado** (proposta → aprovação → execução →
medições → faturamento → encerramento) e o próximo passo; **viabilidade**;
estrutura em fases e atividades com dependências (a partir de modelos);
**alocação de pessoal** por semana ou distribuída no período, com
capacidade (jornada, ausências, feriados), sobrealocação entre projetos e
sugestão de redistribuição; quadro do fluxo; linha do tempo com **caminho
crítico** e linha de base; andamento com valor agregado (IDP, IDC,
estimativa no término); mudanças de escopo com nova linha de base; riscos;
faturamento; relatórios de status agendáveis e sem custos para o cliente.

**Viabilidade e lucro**: desde a proposta, faturamento, impostos, custo
(pessoal pela alocação de cada pessoa, despesas previstas únicas ou mensais,
despesas gerais), lucro, margem e mês a mês — sempre nos cenários **base,
otimista e pessimista**, mais simulações e cenários salvos. A política de
margem da empresa classifica o projeto e exige justificativa para aprovar
abaixo da mínima. Em execução, o lucro previsto soma o realizado ao que
ainda está alocado. Custos e margens só para o gestor do projeto.

**Minha semana** (`semana`): o consultor vê suas atividades e alocação e
aponta horas ou atualiza o andamento ali mesmo. **Portfólio**
(`portfolio`) e **quadro de alocação** (`alocacao`) para a direção.

Os programas desenham com saídas ricas que qualquer programa pode usar:
`ana.metrics`, `ana.board`, `ana.gantt`, `ana.tabs`, `ana.actions` e ações
por linha em `ana.table` (abrir rotina com parâmetros, ou pedir campos e
executar na própria tela). O endereço `#/ops/<módulo>/<rotina>?param=valor`
abre e executa a rotina.

## Execução paralela (spec 022)

```python
results = ana.map("finance.close_customer", [{"customer": c} for c in ids], max_workers=8)
total = sum(r["result"] for r in results if r["ok"])
```

Cada parte é uma execução própria com o mesmo usuário (processo Python,
transação, limites, auditoria ligada à principal). `mode="atomic"` confirma
todas as partes e a principal juntas ou nenhuma (two-phase commit, com
recuperação de transações preparadas órfãs na partida do nó);
`snapshot=True` dá a todas o mesmo instantâneo do banco; `fail_fast=True`
cancela as demais na primeira falha. O paralelismo é limitado por
`max_parallel_parts` (limites da spec 012); se a principal termina ou falha,
as partes são canceladas; em depuração, rodam uma por vez e são desfeitas
junto com a depuração.

## Agendamento de rotinas (spec 018)

Qualquer programa pode ser agendado com cron (fuso do cliente, só dias
úteis), intervalo, data única, calendário ("último dia útil", "n-ésimo dia
útil", com feriados) ou "após outra rotina" (recebendo o resultado dela).
Políticas de concorrência (pular, enfileirar, paralelo), execuções perdidas
(ignorar, uma vez, todas), novas tentativas com espera exponencial, janela de
horário, pausa automática e avisos de falha, atraso e duração anômala. Em
cluster, cada ocorrência roda exatamente uma vez e outro nó assume se o líder
cair.

## Usuários robô e dono de toda execução

Nada roda sem um dono: toda execução de programa (tela, RPC, agendamento,
chamadas aninhadas) e toda tarefa interna tem um usuário ativo responsável,
pessoa ou **robô**, garantido no banco. Robôs são contas não interativas
(sem senha, nunca `admin`) criadas em Administração → Usuários; servem de
"executar como" em rotinas agendadas e de chamador de integrações, com
**chaves de API** (exibidas uma vez, guardadas só como hash, com validade,
IPs permitidos, último uso e revogação). O que o próprio ERP dispara
(sementes, atualização do analítico) pertence ao robô interno `system` e
aparece em Auditoria → Tarefas internas.

```bash
curl -s -XPOST localhost:8080/rpc -H "Authorization: Bearer ana_rk_…" \
  -d '{"jsonrpc":"2.0","method":"demo.hello","params":{},"id":1}'
```

## Trilha de auditoria e retenção (spec 024)

Tudo o que pessoas e robôs fazem fica rastreável em Administração →
Auditoria: cada requisição (quem, como se autenticou, chave, IP, caminho,
status, duração; texto dos comandos do console SQL), logins, execuções (IP,
chave, nó, tempo, CPU, memória, SQL, stack trace Python e trace interno do
núcleo), tarefas internas e alterações administrativas. A ficha de cada
usuário abre a **trilha** dele numa linha do tempo. Em **Retenção** o
administrador define por quantos dias guardar cada categoria (com mínimos
que protegem a auditoria) e vê volume, espaço e expurgos; o expurgo roda todo
dia, em lotes, uma vez por cluster.

## Amigo de SSD (spec 025)

O ERP evita escrita desnecessária: o analítico só recalcula se as vendas ou o
estoque mudaram; acessos são gravados em lote e particionados por dia
(expurgo descarta partições inteiras); execuções curtas geram uma única
escrita; atualizações frequentes não reescrevem índices; sessões e caches
ficam fora do WAL ou em memória; o PostgreSQL usa WAL comprimido e
checkpoints espaçados; logs de contêiner têm rotação. `fsync` e
`full_page_writes` continuam ligados. Na implantação, recomenda-se montar o
disco de dados com `noatime`, manter o TRIM periódico (`systemctl enable
--now fstrim.timer`), não usar swap no SSD de dados e acompanhar o desgaste
(`smartctl -a` / `nvme smart-log`).

## Chamada remota

```bash
TOKEN=$(curl -s -XPOST localhost:8080/api/session -d '{"username":"admin","password":"admin"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -s -XPOST localhost:8080/rpc -H "Authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","method":"projects.log_time","params":{"project":"PRJ-001","task":"4","hours":2,"description":"Driver do rádio"},"id":1}'
```

```python
from ana_client import Ana, AnaRemoteError      # clients/python/ana_client.py
ana = Ana("http://localhost:8080").login("admin", "admin")
order = ana.call("sales.create_order", customer=1, items=[{"product": "CAFE-500", "quantity": 2}])
```

## Segurança, robustez e performance

| | Como |
|---|---|
| Isolamento | cada execução num processo Python próprio: ambiente limpo, sem credenciais, `python -I -S`, sem fork |
| Governança (spec 012) | limites por programa, papel e grupo, sempre abaixo de tetos globais: tempo, CPU (`ITIMER_PROF` + `RLIMIT_CPU`), memória (`RLIMIT_AS`), tempo por SQL, espera por trava, saída, linhas, comandos SQL, concorrência; cotas por usuário; medição de CPU/memória/SQL por execução e ranking de consumo |
| Menor privilégio | SQL de programas em conexões **autenticadas** como `ana_exec` (sem DDL, sem esquema interno; `RESET ROLE` não escala); console como `ana_read` somente leitura e sem custo-hora; núcleo sem superusuário |
| Dono | toda execução e tarefa interna tem um usuário ativo (pessoa ou robô); robôs autenticam por chave de API com hash, validade e IPs permitidos |
| Rastreabilidade | acessos, execuções, CPU e stack traces de pessoas e robôs; trilha por usuário; retenção configurável por categoria |
| Disco | amigo de SSD: escrita só do que mudou, em lote, partições descartáveis, HOT, WAL comprimido |
| Acesso | PBKDF2, sessões UNLOGGED, bloqueio de força bruta, troca de senha obrigatória, grupos de acesso com programas restritos, último admin protegido, auditoria de logins e de alterações |
| HTTP | CSP estrita sem CDN, `nosniff`, `DENY`, limite de corpo, token fora de cookies |
| Prazos e contrapressão | SQL em andamento é cancelado no servidor ao estourar o prazo; limite global de execuções → 503; cotas → 429 |
| Em memória | caches ETS (programas, parâmetros, sessões, perfis, statements preparados), processos Python pré-aquecidos (~10–15 ms por execução simples), PostgreSQL com `shared_buffers`/`work_mem` ajustáveis, `pg_prewarm` com aquecimento automático, JIT |
| Analítico | tabela fato colunar (Citus), visões materializadas com refresh concorrente, BRIN em datas |
| Fuso horário | `ANA_TIMEZONE` aplicado ao banco e aos programas ("hoje" é o do cliente) |

## Testes

```bash
make eunit             # núcleo Erlang
make dialyzer          # análise estática
make teste-runtime     # runtime Python, depurador e limites (sem banco)
make teste-integracao  # testes contra o ambiente, rastreados a CA-xxx-nn
make teste-estudio     # interface num DOM real (jsdom): áreas, rotina, depurador, administração
make teste-cluster     # dois nós: agendamento exatamente uma vez, troca de líder, erpc
make teste-caos        # dois nós + HAProxy: programas que falham, nó derrubado, desligamento
                       # gracioso, atualização rolling, banco reiniciado, restauração a um instante
```

## Estrutura

```
specs/              especificações (constituição + specs com spec/plan/tasks)
src/                núcleo Erlang
priv/migrations/    SQL versionado          priv/demo/      dados de demonstração (ANA_DEMO)
priv/programs/      programas-semente       priv/python/    runtime isolado + depurador
priv/www/           interface (HTML/CSS/JS, sem dependências)
clients/python/     cliente JSON-RPC        tests/          runtime, integration, studio
```

## Operação 24/7 (spec 023)

- **Saúde**: `/health/live` (o processo está de pé) e `/health/ready` (banco,
  pools, Python, esquema compatível e não drenando) — o balanceador usa a
  prontidão; `/health` segue disponível.
- **Vários nós** atrás de um balanceador (sessões ficam no banco). Exemplo
  com HAProxy em `tests/chaos/`.
- **Desligamento gracioso**: no SIGTERM o nó sai da prontidão, espera o
  balanceador perceber (`ANA_DRAIN_DELAY_MS`), recusa novas execuções
  (`DRAINING`, 503), espera as em curso (`ANA_DRAIN_TIMEOUT_MS`) e encerra.
- **Atualização sem parada**: migrações expandir → migrar → contrair;
  uma migração que quebra a versão anterior começa com `-- ana:breaking` e
  tira da prontidão os nós antigos.
- **Banco**: `ANA_DB_HOST=pg1,pg2` encontra o primário e segue a réplica
  promovida sem reiniciar o núcleo; `ANA_DB_READ_HOSTS` leva o console SQL
  às réplicas; banco fora → erro imediato (`DB_UNAVAILABLE`, 503) e volta
  sozinho em segundos.
- **Execuções interrompidas** pela queda de um nó ficam registradas como
  `INTERRUPTED`; sistemas remotos com falha abrem um disjuntor
  (`REMOTE_UNAVAILABLE`) em vez de prender execuções.
- **Cópias de segurança**: `scripts/backup.sh enable` (arquivamento de WAL),
  `scripts/backup.sh base` (cópia base, diária) e `scripts/restore-test.sh
  "<instante>"` (restauração verificada num contêiner descartável). Copie o
  volume `wal_archive` para fora da máquina.

## Fluxo de versionamento (gitflow)

| Branch | Para quê | Recebe de |
|--------|----------|-----------|
| `master` | código de produção; cada versão liberada recebe uma tag `vX.Y.Z` | `qa` (liberação) e `hotfix/*` |
| `qa` | testes e homologação de uma versão candidata | `dev` |
| `dev` | integração do desenvolvimento | `feature/*`, e de volta de `hotfix/*` |
| `feature/NNN-assunto` | uma spec ou mudança (ex.: `feature/023-high-availability`) | criada a partir de `dev` |
| `hotfix/assunto` | correção urgente em produção | criada a partir de `master`; volta para `master` e `dev` |

Regras: nada é commitado direto em `master`, `qa` ou `dev`; cada spec nasce
numa `feature/*` a partir de `dev` e só é integrada com todas as suítes
verdes (`make testes`); `dev → qa` quando há uma versão candidata;
`qa → master` (com tag) só depois de homologada em `qa`. Commits assinados.

## Configuração (principais)

| Variável | Padrão | |
|----------|--------|---|
| `ANA_DB_HOST`, `ANA_DB_PORT`, `ANA_DB_NAME`, `ANA_DB_USER`, `ANA_DB_PASSWORD` | `localhost`, `5432`, `ana`, `ana`, `ana` | conexão do núcleo |
| `ANA_DB_POOL` / `ANA_DB_POOL_EXEC` | `10` / `20` | pools interno / programas |
| `ANA_DB_EXEC_PASSWORD`, `ANA_DB_READ_PASSWORD` | aleatória por partida | **defina em cluster** |
| `ANA_HTTP_PORT`, `ANA_HTTP_MAX_BODY` | `8080`, 2 MiB | |
| `ANA_ADMIN_PASSWORD` | `admin` | senha inicial do admin |
| `ANA_DEMO` | `false` (`true` no compose) | dados de demonstração |
| `ANA_TIMEZONE` | `UTC` (`America/Sao_Paulo` no compose) | fuso do cliente |
| `ANA_PY_PREWARM`, `ANA_PY_SITE` | `4`, `0` | processos Python pré-aquecidos; pacotes do site |
| `ANA_PG_SHARED_BUFFERS`, `ANA_PG_EFFECTIVE_CACHE`, `ANA_PG_WORK_MEM` | `512MB`, `1536MB`, `32MB` | memória do PostgreSQL (compose) |
| `ANA_NODE_NAME`, `ANA_COOKIE` | — | habilitam distribuição Erlang |
| `ANA_DB_HOST` (lista), `ANA_DB_READ_HOSTS` | `localhost`, — | primário com troca automática; réplicas de leitura |
| `ANA_DRAIN_DELAY_MS`, `ANA_DRAIN_TIMEOUT_MS` | `2000`, `25000` | desligamento gracioso |
| `ANA_BREAKER_OPEN_MS` | `30000` | tempo do disjuntor aberto |

Prazos, limites, tetos, cotas, sessão e política de senha são **parâmetros**
editáveis em Administração → Sistema → Parâmetros (as variáveis `ANA_*`
correspondentes são só o valor inicial).

## Situação das specs

Implementadas: 001–008, 011 (com usuários robô e dono obrigatório), 012, 018, 021 (portal do cliente depende da 016), 022, 023 (falta o teste de troca real de primário, T-023-09), 024, 025; 020 parcial (falta próxima ação
sugerida, fluxos guiados e auditoria de acessibilidade).
Na fila (ordem em [scripts/pending-work.prompt.md](scripts/pending-work.prompt.md)):
019 observabilidade, 013 suprimentos, 017 integrações, 016 repositório de
arquivos, 014 produção, 015 logística, 010 API pública; 009 licenciamento
aguarda decisões.
