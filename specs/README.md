# Especificações do ANA ERP (Spec Driven Development)

O ANA ERP é desenvolvido orientado a especificações. **Nenhum código entra sem
uma especificação que o justifique**, e todo teste aponta para o requisito que
verifica.

## Fluxo

```
constituição  →  spec.md  →  plan.md  →  tasks.md  →  código + testes
 (princípios)    (o quê /     (como:      (passos      (rastreados por
                  porquê)      design)     verificáveis) ID de requisito)
```

1. **spec.md** — problema, histórias de usuário, requisitos funcionais
   (`RF-xxx-nn`), não funcionais (`RNF-xxx-nn`) e critérios de aceite
   (`CA-xxx-nn`). Não fala de tecnologia além do necessário.
2. **plan.md** — decisões técnicas, módulos, contratos (APIs, protocolos,
   esquemas) e riscos.
3. **tasks.md** — lista ordenada de tarefas, cada uma citando os requisitos
   que atende. Marcadas `[x]` quando implementadas **e** testadas.
4. **Código e testes** — comentários e nomes de testes citam o ID
   (ex.: `test_ca_002_03_rollback_on_error`).

Mudou o comportamento? Atualize primeiro a spec, depois o código.
As specs são escritas em português; identificadores citados nelas estão em
inglês, como no código (constituição, P2a).

## Índice

| Nº  | Especificação | Assunto | Situação |
|-----|---------------|---------|----------|
| 000 | [Constituição](000-constitution.md) | Princípios inegociáveis | vigente |
| 001 | [Plataforma](001-platform/spec.md) | Núcleo Erlang, PostgreSQL, migrações, segurança | implementada |
| 002 | [Runtime Python](002-python-runtime/spec.md) | Programas em Python armazenados no banco | implementada |
| 003 | [Chamadas remotas](003-remote-calls/spec.md) | Programas expostos via JSON-RPC e distribuição Erlang | implementada |
| 004 | [Depurador](004-debugger/spec.md) | Pontos de parada, passo a passo, inspeção | implementada |
| 005 | [Estúdio](005-studio/spec.md) | Ambiente de desenvolvimento web embutido | implementada |
| 006 | [Módulos de negócio](006-business-modules/spec.md) | Cadastros, estoque, vendas, financeiro | implementada |
| 007 | [Camada analítica](007-analytics/spec.md) | Visões analíticas, colunar opcional | implementada |
| 008 | [Serviços e projetos](008-services-projects/spec.md) | P&D, horas, despesas, protótipos, faturamento | implementada |
| 009 | [Licenciamento](009-licensing/spec.md) | Implantação por cliente, licenças, camadas | rascunho |
| 010 | [API pública](010-public-api/spec.md) | Chamadas pela internet por sites e sistemas de terceiros | especificada |
| 011 | [Administração](011-administration/spec.md) | Usuários e robôs (chaves de API), grupos, parâmetros, monitor, auditoria pela UI; dono obrigatório em toda execução | implementada |
| 012 | [Governança de execução](012-execution-governance/spec.md) | Limites finos de tempo, CPU, memória, SQL, concorrência e cotas | implementada |
| 013 | [Cadeia de suprimentos](013-supply-chain/spec.md) | Fornecedores, compras, aprovação, recebimento, reposição | implementada |
| 014 | [Produção e capacidade](014-production-planning/spec.md) | Estruturas, roteiros, necessidades, ordens, capacidade (bens e serviços) | especificada |
| 015 | [Logística e campo](015-logistics-field-service/spec.md) | Transferências, expedição, devoluções, ordens de serviço, agenda, rotas | especificada |
| 016 | [Repositório de arquivos](016-file-repository/spec.md) | Pastas, versões, permissões granulares, portal do cliente, links | especificada |
| 017 | [Hub de integrações](017-integration-hub/spec.md) | Conectores, cofre, webhooks, extratos, conciliação, gateways | implementada (faltam SFTP/pasta/e-mail, mTLS, CNAB e pacotes de modelos) |
| 018 | [Agendamento](018-scheduler/spec.md) | Rotinas com cron/calendário, cluster, tentativas, dependências | implementada |
| 019 | [Observabilidade](019-observability/spec.md) | Saúde, métricas, rastros, stack traces, perfilamento, dicas | implementada (faltam alertas configuráveis e OpenTelemetry) |
| 020 | [Arquitetura da informação](020-information-architecture/spec.md) | Áreas por tarefa; fluxo coerente (próxima ação, fluxos guiados) | parcial |
| 021 | [Consultoria](021-consulting-projects/spec.md) | Fases, alocação de pessoal, quadro/Gantt e caminho crítico, valor agregado, mudanças, riscos, viabilidade e lucro (base/otimista/pessimista), portfólio | implementada (portal: 016) |
| 022 | [Execução paralela](022-parallel-execution/spec.md) | `ana.parallel`/`ana.map`: dividir e juntar, atômico ou independente | implementada |
| 023 | [Alta disponibilidade](023-high-availability/spec.md) | Operação 24/7, drenagem, rolling, banco HA, testes de caos | implementada |
| 024 | [Trilha de auditoria e retenção](024-audit-trail-retention/spec.md) | Acessos, execuções, CPU e stack traces de pessoas e robôs; trilha por usuário; retenção configurável | implementada |
| 025 | [Uso eficiente de disco](025-storage-efficiency/spec.md) | Amigo de SSD: só grava o que mudou, lotes, partições, HOT, WAL comprimido | implementada |
| 026 | [Gráficos](026-charts/spec.md) | `ana.chart`: linha, área, colunas, empilhadas, barras, rosca; paleta validada para daltonismo, legenda, dicas e tabela | implementada |
| 027 | [Centros de custo](027-cost-centers/spec.md) | Centro em cada lançamento (política por conta, garantida no banco), origem automática, hierarquia, orçado × realizado, rateio, lançamento manual, resultado gerencial | implementada |
| 028 | [Atualização dos programas do produto](028-product-updates/spec.md) | Versão nova de programa do produto oferecida a instalações existentes; administrador compara lado a lado e aceita ou dispensa | implementada |

## Glossário

| Termo (docs) | Identificador (código) | Significado |
|--------------|------------------------|-------------|
| Programa | `program` | Código Python versionado no banco, executado pelo núcleo. |
| Programa exposto | `exposed = true` | Programa chamável de fora do ERP (JSON-RPC). |
| Biblioteca | `kind = 'library'` | Programa importável por outros (`import ana_lib.<nome>`). |
| Unidade de Trabalho | *execution transaction* | Transação única que envolve uma execução inteira, incluindo chamadas aninhadas. |
| Execução | `execution` | Registro de uma rodada de um programa: parâmetros, saída, resultado, status. |
| Comando | `command` | Atalho curto digitado na barra do Estúdio que abre um programa. |
| Estúdio | `studio` | IDE web embutida: editor, executor, depurador, catálogo, console SQL. |
| Catálogo | `catalog` | Dicionário de dados derivado do PostgreSQL. |
| Sistema remoto | `remote_system` | Outro ANA (ou compatível) que recebe chamadas de saída. |
| Cliente de API | `api_client` | Site ou sistema de terceiros autorizado a chamar programas expostos (spec 010). |
| Parte | `party` | Cliente e/ou fornecedor. |
| Item | `product` (`kind`: `goods` \| `service`) | O que se vende ou consome. |
| Projeto | `project` | Trabalho contratado por um cliente, com orçamento, equipe, tarefas e forma de cobrança. |
| Apontamento | `time_entry` | Horas de um colaborador numa tarefa de projeto. |
| Marco | `milestone` | Entrega com valor fixo (ex.: protótipo), faturada quando concluída. |
| Fatura de serviço | `projects.invoice` | Cobrança gerada de horas aprovadas, despesas refaturáveis e marcos. |
| Título | `finance.bill` | Valor a receber ou a pagar, com vencimento. |

## Mapa de nomes (código)

| Área | Esquema | Principais tabelas |
|------|---------|--------------------|
| Interno | `ana_system` | `app_user`, `session`, `access_group`, `user_group`, `setting`, `program`, `program_version`, `execution`, `remote_system`, `command`, `login_event`, `admin_log`, `api_client` |
| Cadastros | `base` | `company`, `party`, `product` |
| Estoque | `inventory` | `warehouse`, `stock_movement` |
| Vendas | `sales` | `sales_order`, `sales_order_item` |
| Financeiro | `finance` | `account`, `default_account`, `journal_entry`, `journal_line`, `bill` |
| Projetos | `projects` | `rate_profile`, `employee`, `project`, `project_rate`, `task`, `project_member`, `time_entry`, `expense`, `milestone`, `invoice`, `invoice_line` |
| Analítico | `analytics` | `sales_fact`, `daily_sales`, `sales_by_customer`, `stock_balance` |

Papéis de usuário: `admin`, `developer`, `user`. Papéis PostgreSQL: `ana`
(dono), `ana_exec` (programas), `ana_read` (console SQL).
