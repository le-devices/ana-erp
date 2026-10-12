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

## Linguagem visual "Linha ANA" (spec 029)

Identidade própria (logotipo, ícones em SVG, paleta, fonte do sistema),
inspirada em páginas analíticas de ERPs corporativos sem usar fonte, ícones,
temas ou marcas de terceiros. Barra superior compacta (conta, voltar, marca,
áreas como abas sempre visíveis, busca e avisos); cada rotina é uma página
analítica — faixa de cabeçalho com filtros em linha, indicadores como chips
de estado, gráficos lado a lado em cartões e tabelas em cartão com
"Título (N)" e exportação; início em blocos. Tema claro e escuro, sem
rolagem horizontal no celular.

Formulários (spec 031): cliente, depósito, OS, técnico, conta, condição etc.
são listas; linhas (itens de pedido, componentes, operações, faixas de frete,
lançamentos) são grades com "Adicionar linha"; datas e horas têm botão de
calendário/relógio e "hoje"/"agora"; números aceitam vírgula decimal. Todo
campo tem rótulo em português (verificado por teste).

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
| `chart` | gráficos: linha, área, colunas, empilhadas, barras e rosca (paleta validada para daltonismo, legenda, dicas, tabela) |
| `context` | usuário, papel, execução, versão, origem |
| `Error(code, message, data)` | erro de negócio estruturado |
| `SqlError` | erro do banco (`sqlstate`); regra de gatilho que levanta `'CODIGO: mensagem'` (check_violation) chega a quem chamou com esse código |

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
- **Centros de custo** (spec 027): cada lançamento de receita e despesa tem
  centro de custo (garantido no banco para qualquer programa), vindo do
  pedido, do depósito, do projeto ou do padrão da empresa; hierarquia com
  consolidação, orçamento × realizado, **rateio** de custos compartilhados
  (prévia, uma vez por mês), lançamento manual e resultado gerencial por
  centro com gráficos (`centros`); balancete filtrável por centro.
- **Suprimentos** (spec 013): catálogo de fornecimento (preço, prazo, lote,
  preferencial), solicitação de compra com **alçadas** por papel ou grupo
  (quem pede não aprova), ordens por fornecedor, recebimento parcial ou
  aceite de serviço numa só transação (estoque ou despesa do projeto,
  lançamento com centro de custo e título a pagar; o banco recusa receber
  acima da tolerância), sugestão de reposição por conjunto (saldo + em
  pedido − reservado), desempenho de fornecedores e confirmação de prazo
  exposta para integração. Tudo começa na bancada `compras`.

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
make teste-pg-ha       # PostgreSQL primário + réplica: promoção com carga, console na réplica, primário antigo recusado
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

## Observabilidade e desempenho do SQL (spec 019)

- **Desempenho do SQL** (Administração → Observabilidade): cada comando de
  cada programa é medido (tempo, linhas, linha do programa) e agregado; os
  lentos ganham plano (`EXPLAIN`, sem executar) e sugestão concreta, como o
  `CREATE INDEX CONCURRENTLY` com as colunas do filtro.
- **Análise do SQL do código** (aba Desempenho do programa): `SELECT *`,
  `LIKE '%…'`, função sobre coluna no filtro, `UPDATE`/`DELETE` sem `WHERE`,
  paginação por `OFFSET`, `NOT IN (SELECT…)`, SQL montado com valores
  recebidos (injeção) e SQL dentro de laço (N+1) — com a linha e a correção.
- **Dicas de otimização**: N+1 observado, varredura completa lenta,
  **crescimento** (a consulta rápida hoje que vai ficar lenta com a tabela
  crescendo, com projeção de 6 meses), FK sem índice, índice nunca usado,
  espaço morto, programa perto do limite, prazos estourados. Dispensar por
  30 dias ou sempre; resolvidas somem sozinhas.
- **Saúde e incidentes**: componentes verificados a cada 10 s, incidentes
  abertos/fechados automaticamente (inclusive com o banco fora), webhook
  opcional (`ANA_ALERT_WEBHOOK`).
- **Execução detalhada**: linha do tempo do SQL, quadros e variáveis do erro
  (só para desenvolvedores, nomes sensíveis mascarados) e **perfil** sob
  demanda ("Perfilar uma execução").
- **Métricas** em `/metrics` (Prometheus, autenticado) e logs JSON com
  `ANA_LOG_FORMAT=json`.

## Produção e capacidade (spec 014)

Bancada `producao`: estruturas em versões (componentes, perda, fantasmas; o
banco recusa ciclos), roteiros com recursos (máquina, bancada, linha,
pessoas; h/dia, eficiência, exceções, custo/h) e parâmetros de item (fazer
ou comprar, prazo, lote, segurança, custo padrão).

- **Planejamento de necessidades** (`mrp`): explode as estruturas nível a
  nível em lote, desconta saldo, ordens e compras em aberto e propõe ordens
  de produção e solicitações de compra com as datas deslocadas pelos
  prazos; idempotente por cenário; 10 mil itens × 5 níveis em ~2 s.
- **Ordem de produção**: liberar (reserva), requisitar (baixa, D produtos
  em elaboração), apontar horas (custo do recurso), entregar (entrada do
  acabado) e encerrar com custo real imutável e variação contra o padrão;
  ordem de protótipos de um projeto vira despesa do projeto.
- **Carga × capacidade** (`carga`) por recurso e semana, com sobrecarga e
  data sugerida por capacidade finita; **capacidade de serviços**
  (`capacidade`) por colaborador e perfil a partir da alocação dos projetos.

## Logística e serviços em campo (spec 015)

- **Logística** (bancada `expedicao`): transferências entre depósitos com
  trânsito e divergência registrada; expedição total ou parcial (separar,
  embalar, despachar, entregar ou voltar) com transportadora, rastreio e
  frete pela tabela (UF, peso); baixa do estoque no faturamento ou na
  expedição (`logistics.policy.stock_out_on`), frete cobrado vai à fatura;
  devoluções para o estoque ou a quarentena, com crédito ao cliente.
- **Campo** (bancada `campo`): ordem de serviço com prazo de SLA (por
  prioridade ou contrato do cliente), aberta também pelo cliente no portal;
  agenda sem sobreposição garantida no banco e respeitando ausências; rota do
  dia; apontamento de deslocamento e horas, peças do estoque do técnico,
  checklist e aceite — tudo idempotente pela chave do app; faturamento
  (horas × valor do perfil, deslocamento, peças) ou lançamento no projeto;
  indicadores (`sla`): SLA cumprido, atrasadas, resposta, horas em campo,
  visitas e retornos.

## Instalação em produção (spec 036)

Guia completo: [deploy/INSTALL.md](deploy/INSTALL.md) — servidor próprio,
VM em qualquer nuvem ou Kubernetes. Em resumo:

```bash
sudo ./deploy/install.sh --domain erp.empresa.com.br --email ti@empresa.com.br
sudo /opt/ana-erp/ana-ctl doctor
```

O instalador confere os requisitos, gera todas as senhas e chaves, sobe banco
(com arquivamento contínuo), dois nós e o proxy HTTPS, faz a primeira cópia e
agenda as cópias; o admin troca a senha inicial no primeiro acesso.
`ana-ctl upgrade --source <pacote novo>` atualiza nó a nó sem parar (e volta
atrás se falhar). O `docker-compose.yml` da raiz é o ambiente de
**desenvolvimento** (senhas de exemplo, dados de demonstração).

## Documentos navegáveis (spec 035)

Onde uma lista mostra um documento — faturas, pedidos, OS, solicitações e
ordens de compra, ordens de produção, expedições, transferências — a linha é
clicável (ou Enter pelo teclado) e abre o documento (`doc`): cabeçalho,
itens, valores, situação, histórico, documentos ligados (que também abrem) e
o próximo passo. No portal, o cliente abre só os próprios pedidos, faturas e
OS. A fatura de pedido ou de OS tem PDF (itens, parcelas, vencimentos e dados
de pagamento), gerado no faturamento e guardado na pasta "Faturas" do
cliente — o título e Minhas faturas abrem o PDF numa aba.

## Documentos para clientes e fornecedores (spec 037)

Pedido, fatura, comprovante de entrega, relatório de atendimento da OS,
recibo, extrato e ordem de compra têm PDF, gerado nos eventos (pedido criado,
expedição, aceite da OS, ordem enviada, pagamento) ou sob demanda, e
**publicado** numa subpasta da pasta do parceiro feita para ele (Pedidos,
Faturas, Entregas, Atendimentos, Recibos, Extratos, Ordens de compra). No
portal, **Meus documentos** (`documentos`) lista e baixa esses PDFs; para
quem não tem conta, **Link para o cliente** (`link_doc`) cria um endereço de
download com validade, limite e senha; o endereço usado nos links é o
"Endereço público do ERP" (Administração → Empresa; valor inicial do
instalador, `ANA_PUBLIC_URL`).

**Regra**: clientes e fornecedores nunca alcançam documento interno. O núcleo
só publica tipos externos de uma lista fechada e recusa dar acesso a conta
externa — ou criar link de download — fora das pastas para parceiros. Só um
administrador marca outra pasta como "para parceiros" (Arquivos), e isso fica
na auditoria.

## Distâncias (spec 032)

Empresa (Administração → Empresa), depósitos (`inventory.save_warehouse`) e
clientes (`party`) têm latitude e longitude (vírgula ou ponto). `distancia`
mostra a distância em linha reta (haversine, no banco), a rodoviária
aproximada (reta × fator, padrão 1,3) e o tempo estimado (velocidade média,
padrão 50 km/h) — sem serviço externo; `clientes_distancia` lista clientes
por raio e quem ainda não tem coordenadas. Ao agendar uma OS sem informar
distância, o ERP calcula a partir da base do técnico; a tabela de frete pode
ter faixas de distância. Parâmetros e geocodificação opcional (por conector,
spec 017) em `base.geo_settings`.

## Esteiras de processos (spec 030)

Operação → Esteiras: cada documento segue sua esteira e a etapa seguinte
acontece sozinha quando a anterior termina — ou espera uma pessoa, conforme
a regra da empresa.

- **Venda**: pedido → expedição (baixa e movimentação do estoque) →
  faturamento (títulos por parcela) → cobrança (PIX/boleto/cartão pelo
  gateway) → recebimento. **Compras**: solicitação → aprovação → ordem ao
  fornecedor → recebimento → pagamento. **Campo**: chamado → agendamento →
  execução e aceite → faturamento → cobrança → recebimento. **Produção**:
  ordem → liberação → requisição dos componentes → fabricação →
  encerramento.
- Em `esteira_config` (administrador): ligar (nasce desligada), incluir os
  documentos em aberto, escolher o robô que executa e, por etapa, automática
  ou manual, com condições sobre o documento (ex.: faturar sozinho só até
  R$ 5.000; condição não cumprida = espera uma pessoa).
- O quadro (`esteiras`) mostra cada documento na sua etapa, por que espera,
  falhas com o motivo (cliente bloqueado, falta de estoque…) e as ações:
  fazer agora (abre a rotina com o documento preenchido), executar
  automaticamente, reprocessar, pular com motivo. O que alguém fizer à mão,
  fora da esteira, também a faz andar.
- A esteira começa na mesma transação que cria o documento; o motor roda no
  nó líder, com nova tentativa em falhas técnicas e retomada se um nó cair.

## Condições de pagamento e crédito (spec 031)

- **Condições** (`condicao`): forma (PIX, boleto, cartão de crédito/débito,
  crédito direto, dinheiro, transferência), prazos "30/60/90" ou parcelas com
  percentuais (o banco confere a soma de 100 %), entrada, desconto/acréscimo,
  taxa da operadora, valor mínimo e conector de cobrança (spec 017). O
  faturamento gera um título por parcela (centavos na última) e, com
  conector, a cobrança de cada parcela. Condições permitidas e padrão por
  cliente.
- **Crédito** (`credito`): limite por cliente, tolerância de atraso e
  bloqueio automático por inadimplência — **desligado de fábrica** (ligar de
  saída bloquearia clientes com títulos antigos); bloqueio manual com motivo
  e validade; liberação pontual de um pedido ou faturamento, usada uma vez.
  O bloqueio impede novos pedidos, faturamentos e ordens de serviço
  (`CUSTOMER_BLOCKED`); tudo registra quem, quando e por quê.
- **Tela de venda** (`order`): itens numa grade com saldo no depósito e nos
  outros; se faltar, só avisa (com "Transferir de X"), pede a transferência
  ou recusa; mostra as parcelas e leva a "Faturar agora" ou "Expedir".

## Verificações periódicas (spec 033)

Administração → Observabilidade → **Verificações**: o robô `system` confere,
no nó líder, a **segurança** da configuração (senha trivial em conta
privilegiada, chave mestra/senha do banco/cookie de exemplo, política de
senha e sessão, administradores demais, chaves de API paradas ou sem
validade, links abertos, conectores sem hosts permitidos, retenção curta), os
**componentes** com vulnerabilidade conhecida, a **integridade** dos arquivos
do produto (manifesto SHA-256 gerado na construção da imagem), a
**robustez** (arquivamento do WAL, idade da última cópia completa e do último
teste de restauração — registradas por `scripts/backup.sh` e
`scripts/restore-test.sh` —, filas de falha, disjuntores, falhas técnicas,
disco do repositório) e o **desempenho** (sondas a cada 5 min; aviso quando o
p95 da última hora passa do fator da linha de base de 7 dias). Segurança,
integridade e componentes rodam diariamente; robustez a cada 15 min;
desempenho a cada hora; e sob demanda. Achado crítico novo acende o sino dos
administradores; achados podem ser dispensados (voltam se piorarem).

O **inventário** lista ANA, OTP e bibliotecas, Python, PostgreSQL e
extensões e os pacotes Debian da imagem. A **base de vulnerabilidades** está
no formato OSV: baixe em osv.dev os avisos de Hex, Debian e PyPI e envie em
Verificações → Inventário (nada é consultado na internet sem o administrador
pedir). Avisos retirados (`withdrawn`) removem o aviso anterior.

## Desenvolvimento, testes e transporte para produção (spec 034)

Cada instalação tem um papel: `ANA_INSTANCE=production` (padrão), `test` ou
`development` (o `docker-compose.yml` deste repositório é `development`).
Fora da produção uma faixa "DESENVOLVIMENTO"/"TESTES" aparece em todas as
telas. Com o parâmetro `transport_required = 1`, a produção só aceita
mudanças de programas por pacote.

- **Transportes** (Administração → Sistema): na instância de desenvolvimento
  monte o pacote (programas, comandos, parâmetros, o que muda, testes feitos)
  e gere o arquivo assinado com a chave Ed25519 da instância (guardada no
  cofre). Na produção, cadastre a origem (nome + chave pública), receba o
  arquivo: assinatura, hashes e versão do produto são conferidos e a
  verificação prévia mostra o que é novo, igual, atualização ou **conflito**
  (programa alterado na produção depois da origem — só segue com aceite
  explícito, com comparação lado a lado) e dependências ausentes. Importar
  grava tudo numa transação, como versões novas, sem parar o sistema
  (execuções em andamento terminam na versão em que começaram); desfazer
  volta tudo ao estado anterior. Quatro olhos opcional
  (`transport_four_eyes`).
- **Cópia de dados para testes**: na produção, "Exportar dados mascarados"
  gera um retrato consistente dos esquemas de negócio com nomes, e-mails,
  telefones, documentos, endereços, coordenadas e observações **mascarados
  na origem** (determinístico dentro da cópia: o mesmo cliente é o mesmo em
  todas as tabelas), comprimido e cifrado; a chave aparece uma vez e o
  arquivo fica 48 h. Na instância de testes, envie o arquivo, ensaie (carga
  completa desfeita ao final) e importe: tudo numa transação, contagens e
  totais conferidos; depois os conectores são desligados e as chamadas
  externas bloqueadas (`outbound_blocked`). Tabelas do sistema, cofre,
  integrações, arquivos e senhas nunca entram. A aba Máscaras mostra e ajusta
  o catálogo por coluna.

## Repositório de arquivos e portal do cliente (spec 016)

**Arquivos** guarda documentos de projetos, clientes e fornecedores em pastas
com versões imutáveis. Acesso por usuário, grupo, papel ou **cliente**
(`ver` < `baixar` < `enviar` < `gerenciar`), herdado pelas pastas (a herança
pode ser interrompida) e com negação explícita; o que não pode ver é 404.
O conteúdo fica fora do banco (`ANA_FILES_DIR`, volume compartilhado pelos
nós), cifrado (AES-256-CTR + HMAC, chave derivada da `ANA_MASTER_KEY`) e
deduplicado pelo SHA-256; o nome nunca vira caminho no disco. Downloads só
por URL assinada de 5 min (`attachment`, `nosniff`, `Range`); links de
compartilhamento com validade, senha e limite de downloads; envio retomável;
tipo real conferido pela assinatura (um `.exe` renomeado é recusado);
auditoria de cada operação; verificação periódica de integridade.

- Contas de **portal** (papel `external`, ligadas a um cliente) veem só
  Arquivos e as consultas marcadas `# ana:portal yes`: **Minhas faturas**
  (`faturas`), **Meus projetos** (`meusprojetos`: andamento, marcos,
  próximos passos e riscos do último relatório de status, sem custos) e
  **Aprovações** (`aprovacoes`: aceite de entregáveis e aprovação de
  mudanças de escopo, que ajusta orçamento, prazo e linha de base).
- Faturas de serviço viram PDF em `Clientes/<cliente>/Faturas`, liberado ao
  cliente; projetos têm `Projetos/<código>/Entregáveis`.
- Programas: `ana.files.put/get/list/folder/grant` (com as permissões de quem
  executa); `util.pdf` gera PDFs simples.
- **Backup:** inclua o volume de arquivos junto com o do banco.

## Integrações e conciliação bancária (spec 017)

Programas nunca fazem rede nem veem segredos. Em **Administração → Operação
do sistema → Integrações** o administrador cadastra **conectores** (URL base,
hosts permitidos, autenticação, limite por minuto, programa de entrega e de
processamento, usuário dono); os segredos vão para um **cofre** cifrado
(AES-256-GCM, `ANA_MASTER_KEY` igual em todos os nós) e são só de escrita.

- `ana.http("banco_x", "GET", "/extratos", params={...})` — o núcleo põe a
  credencial, confere o host, aplica prazo, limite, disjuntor e registra.
- `ana.send("gateway", "charge.create", dados)` — caixa de saída na mesma
  transação: só sai se a execução confirmar; entrega com novas tentativas
  (10 s × 2ⁿ) e fila de mortos com reprocessar.
- Webhooks em `POST /hooks/<conector>` com HMAC-SHA256 de `carimbo.corpo`,
  janela anti-repetição e idempotência pelo id do evento.
- Extratos OFX/CSV sem duplicar (`extrato`), conciliação automática por
  cobrança, documento e valor + data, e bancada manual (`conciliar`) com
  baixa agrupada, juros/tarifas e estorno; cobrança por gateway
  (`finance.create_charge`) liquidada pelo aviso de pagamento.
- Modelo de conector de gateway: `integration.generic_gateway_out` / `_in`.

## Atualização dos programas do produto (spec 028)

As sementes (`priv/programs`) nunca sobrescrevem um programa instalado. Ao
subir, cada nó compara cada semente com o programa e com a versão do produto
em que ele se baseia: quando o produto traz versão nova, aparece em
**Administração → Sistema → Atualizações do produto** (com contador). O
administrador compara lado a lado (instalado × produto, o que foi alterado
aqui, o que o produto mudou) e aceita — vira nova versão, com histórico — ou
dispensa. Programa alterado nesta instalação só é sobrescrito com
confirmação explícita; "aceitar as não alteradas" atualiza o resto de uma vez.

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
  promovida sem reiniciar o núcleo (entre dois que se dizem primários, vale
  o da linha do tempo mais nova — um primário antigo que volte sem ser
  rebaixado nunca recebe gravações; testado com cluster local em
  `make teste-pg-ha`); `ANA_DB_READ_HOSTS` leva o console SQL
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

Implementadas: 001–008, 011 (com usuários robô e dono obrigatório), 012, 018, 021, 019 (faltam alertas configuráveis e OpenTelemetry), 013, 014, 015, 016 (faltam S3 e antivírus), 017 (faltam SFTP/pasta/e-mail, mTLS, CNAB e pacotes de modelos), 022, 023, 024, 025, 026, 027, 028, 029, 030, 031, 032, 033, 035, 036, 037 (falta base OSV por conector), 034 (faltam agendamentos e migrações no pacote, envio por conector); 020 parcial (falta próxima ação
sugerida, fluxos guiados e auditoria de acessibilidade).
Na fila (ordem em [scripts/pending-work.prompt.md](scripts/pending-work.prompt.md)):
010 API pública; 009 licenciamento aguarda decisões.
