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
| 009 | [Licenciamento](009-licensing/spec.md) | Implantação por cliente, licença assinada sem internet, módulos, usuários nomeados, vencimento com modo somente consulta, versão máxima, camadas de programas; extensões, permissão por dado, marca e telemetria | implementada (empresa/CNPJ na permissão por dado aguarda documentos por empresa) |
| 010 | [API pública](010-public-api/spec.md) | Chamadas pela internet por sites e sistemas de terceiros: clientes com segredo e token Ed25519, chave publicável para sites, escopos, limites e cota, idempotência, assinatura HMAC, auditoria | implementada (faltam PKCE, TOTP, HTTP/2 e cache; vazão-alvo depende de decisão) |
| 011 | [Administração](011-administration/spec.md) | Usuários e robôs (chaves de API), grupos, parâmetros, monitor, auditoria pela UI; dono obrigatório em toda execução | implementada |
| 012 | [Governança de execução](012-execution-governance/spec.md) | Limites finos de tempo, CPU, memória, SQL, concorrência e cotas | implementada |
| 013 | [Cadeia de suprimentos](013-supply-chain/spec.md) | Fornecedores, compras, aprovação, recebimento, reposição | implementada |
| 014 | [Produção e capacidade](014-production-planning/spec.md) | Estruturas, roteiros, necessidades, ordens, capacidade (bens e serviços) | implementada |
| 015 | [Logística e campo](015-logistics-field-service/spec.md) | Transferências, expedição, devoluções, ordens de serviço, agenda, rotas | implementada |
| 016 | [Repositório de arquivos](016-file-repository/spec.md) | Pastas, versões, permissões granulares, portal do cliente, links | implementada (faltam S3 e antivírus) |
| 017 | [Hub de integrações](017-integration-hub/spec.md) | Conectores, cofre, webhooks, extratos, conciliação, gateways | implementada (faltam SFTP/pasta/e-mail, mTLS, CNAB e pacotes de modelos) |
| 018 | [Agendamento](018-scheduler/spec.md) | Rotinas com cron/calendário, cluster, tentativas, dependências | implementada |
| 019 | [Observabilidade](019-observability/spec.md) | Saúde, métricas, rastros, stack traces, perfilamento, dicas | implementada (falta OpenTelemetry) |
| 020 | [Arquitetura da informação](020-information-architecture/spec.md) | Áreas por tarefa; fluxo coerente (próxima ação, fluxos guiados); acessibilidade; padrões de produtividade (simulação ao lado, construtor de condições, grade de planejamento com gráfico); rotinas por área e categoria, categorias pessoais e da empresa | implementada (RF-020-13..18 a implementar) |
| 021 | [Consultoria](021-consulting-projects/spec.md) | Fases, alocação de pessoal, quadro/Gantt e caminho crítico, valor agregado, mudanças, riscos, viabilidade e lucro (base/otimista/pessimista), portfólio | implementada |
| 022 | [Execução paralela](022-parallel-execution/spec.md) | `ana.parallel`/`ana.map`: dividir e juntar, atômico ou independente | implementada |
| 023 | [Alta disponibilidade](023-high-availability/spec.md) | Operação 24/7, drenagem, rolling, banco HA, testes de caos | implementada |
| 024 | [Trilha de auditoria e retenção](024-audit-trail-retention/spec.md) | Acessos, execuções, CPU e stack traces de pessoas e robôs; trilha por usuário; retenção configurável | implementada |
| 025 | [Uso eficiente de disco](025-storage-efficiency/spec.md) | Amigo de SSD: só grava o que mudou, lotes, partições, HOT, WAL comprimido | implementada |
| 026 | [Gráficos](026-charts/spec.md) | `ana.chart`: linha, área, colunas, empilhadas, barras, rosca; paleta validada para daltonismo, legenda, dicas e tabela | implementada |
| 027 | [Centros de custo](027-cost-centers/spec.md) | Centro em cada lançamento (política por conta, garantida no banco), origem automática, hierarquia, orçado × realizado, rateio, lançamento manual, resultado gerencial | implementada |
| 028 | [Atualização dos programas do produto](028-product-updates/spec.md) | Versão nova de programa do produto oferecida a instalações existentes; administrador compara lado a lado e aceita ou dispensa | implementada |
| 029 | [Linguagem visual "Linha ANA"](029-visual-language/spec.md) | Barra superior compacta, rotinas como páginas analíticas (indicadores, gráficos em cartões, tabelas em cartão), início em blocos, ícones próprios, claro/escuro | implementada |
| 030 | [Esteiras de processos](030-automated-flows/spec.md) | Venda → expedição → faturamento → cobrança → recebimento, e compras, campo e produção; etapa automática ou manual com condições, robô dono, falhas com motivo e reprocessamento, quadro por etapa | implementada |
| 031 | [Condições de pagamento e crédito](031-payment-terms-credit/spec.md) | PIX, boleto, cartão, crédito direto e vários prazos; títulos por parcela; limite de crédito, bloqueio por inadimplência e liberação pontual; tela de venda com grade de itens e saldo por depósito | implementada |
| 032 | [Geolocalização e distâncias](032-distances/spec.md) | Coordenadas em empresa, depósitos e clientes; distância em linha reta e rodoviária aproximada com tempo estimado; uso no agendamento de OS, frete por faixa de distância e relatório de clientes por distância; geocodificação opcional por conector | implementada |
| 033 | [Verificações periódicas](033-periodic-checks/spec.md) | Segurança da configuração, componentes com vulnerabilidade conhecida (base OSV), integridade dos arquivos do produto, robustez (cópias, restauração, filas, erros) e desempenho (sondas com linha de base), pelo robô system, com avisos no sino | implementada |
| 034 | [Instância de desenvolvimento e testes](034-dev-test-instance/spec.md) | Papel da instância na tela; pacote de transporte assinado (programas, comandos, parâmetros) com verificação prévia, importação atômica sem parada e desfazer; cópia de dados da produção mascarada na origem, cifrada, com ensaio e bloqueio de chamadas externas | implementada (faltam T-034-07b..09b) |
| 035 | [Documentos navegáveis](035-document-navigation/spec.md) | Clicar numa fatura, pedido, OS, ordem, expedição ou lançamento abre o documento com itens, valores, situação e documentos ligados; portal só vê os seus | implementada |
| 036 | [Instalação local e na nuvem](036-installation/spec.md) | Instalador com segredos gerados e HTTPS, dois nós, cópias agendadas, `ana-ctl` (diagnóstico, atualização sem parada, volta atrás, desinstalação), Kubernetes e banco gerenciado, guia passo a passo | implementada |
| 037 | [Documentos para clientes e fornecedores](037-customer-documents/spec.md) | PDFs de pedido, fatura, entrega, atendimento, recibo, extrato e ordem de compra; publicados só em pastas para parceiros; portal "Meus documentos" e link de download controlado, também por e-mail; documento interno nunca chega ao cliente | implementada |
| 038 | [Processos integrados e conciliação automática](038-integrated-processes/spec.md) | Estoque com valor (custo médio) e lançamento automático pelo banco, inventário físico, perdas e quarentena, frete com título da transportadora, conta de controle nos títulos, conciliação automática dos razões auxiliares com aviso, fechamento de período, baixas exatas com residual/crédito e compensação, extrato com regras, transferências e saldo, repasse do gateway, cancelamento de faturas, nota do fornecedor por confronto, devolução ao fornecedor, custo das horas, marco ligado ao entregável, rotinas prontas | implementada |
| 039 | [BPM: modelar, simular, executar e acompanhar processos](039-bpm/spec.md) | Mapa de processos, editor visual com notação BPMN, validação, versões, modelos prontos, simulação com cenários e calibração pela realidade, motor com tarefas humanas e prazos, painel com mapa de calor, descoberta do processo real | implementada (faltam arrastar da paleta e início por agendamento/mensagem) |
| 040 | [Dados mestres padronizados](040-master-data/spec.md) | Registro declarativo das entidades mestres: lista, ficha, busca, validações (CPF/CNPJ, CEP…), desativar, histórico campo a campo, duplicados e mesclagem, importação CSV com prévia, aprovação de campos sensíveis, painel de qualidade | implementada (falta importação em lote rápida) |
| 041 | [Atendimento do pedido conforme a política da empresa](041-sales-fulfillment-policy/spec.md) | Por instalação, com exceções por item e cliente: vender só com estoque (recusar ou reter), suprir a falta pela compra ou pela produção (com compra dos insumos), ou aceitar sem estoque definido; reserva e vínculo pedido ↔ compra ↔ produção; data prometida | implementada |
| 042 | [Vistoria das trilhas de processos de negócio](042-process-trail-audit/spec.md) | Venda, compra, produção, campo, projetos, atendimento sob encomenda, estoque e esteiras percorridos de ponta a ponta; achados e correções propostas | implementada (vistoria, correções e suíte `make teste-trilhas`) |
| 043 | [Cadastro fiscal de pessoas](043-fiscal-registry/spec.md) | CNPJ alfanumérico e CPF validados no banco em todo cadastro, tipo de pessoa, inscrições estadual e municipal, contribuinte, regime tributário, filiais pela raiz, consulta opcional por conector | implementada (falta dígito da IE por UF, T-043-02b) |
| 044 | [E-mail de saída (SMTP)](044-outbound-email/spec.md) | SMTP como tipo de conector (TLS/STARTTLS, cofre), `ana.send_email` transacional pela fila, modelos com escape, novas tentativas, destino de alertas | implementada |
| 045 | [Variantes de execução](045-execution-variants/spec.md) | Parâmetros salvos com nome, pessoais e da empresa, valores dinâmicos, campos protegidos e ocultos; na tela, no agendamento, na API e nos atalhos | implementada (falta paleta e painel) |
| 046 | [Diagnósticos de programas](046-diagnostics/spec.md) | Agregados diários de longo prazo (erros, CPU, memória, E/S, lentidão), grupos de erro por assinatura, dono e usuários afetados, perguntas prontas e aprofundamento até a pilha | especificada |
| 047 | [Acesso emergencial e depuração em produção](047-emergency-access-debug/spec.md) | Perfil temporário com motivo, prazo e aprovador, registro e revisão; depuração por reexecução sem gravar; ponto de parada ao vivo para outro usuário; pontos condicionais, de registro, em exceção e observação | especificada |
| 048 | [Painel inicial](048-home-panel/spec.md) | Blocos com indicador ao vivo, espaços publicados por grupo de acesso, personalização, contadores e busca global | implementada (blocos sugeridos pelo uso: spec 051; modo TV: 054) |
| 049 | [Motor de impostos](049-tax-engine/spec.md) | Serviço único de cálculo tributário para todo o sistema; regras como dados com vigência, fórmulas fechadas, casos de teste, pacotes de regras; fases: serviços, retenções e Simples → CBS/IBS/IS da reforma → ICMS/IPI/PIS/COFINS; legislação é dado (P21) | fases 1 e 3 implementadas |
| 050 | [Experiência premium](050-premium-experience/spec.md) | Padrão de UX verificado automaticamente (falha a bateria), orçamento de desempenho, paleta de comandos, desfazer, valores padrão por contexto, câmera para código de barras; auditoria de todas as áreas | implementada (fases 1–3: verificador, mensagens, medição das telas, padrões; paleta, atalhos, desfazer, confirmação, valores pelo contexto, câmera; todas as telas verificadas pelo rastreador e auditoria por área; faltam T-050-17..20) |
| 051 | [Automação por padrão](051-automation-by-default/spec.md) | Central de automações, regras "quando… então…" sem código com ensaio, sugestões a partir do uso, exceções como tarefas; auditoria de automação por área | implementada (com a auditoria por área T-051-06; faltam T-051-04b e T-051-07) |
| 052 | [Assistente que executa com segurança](052-safe-assistant/spec.md) | Linguagem natural com as permissões de quem pede; ensaia, mostra e só grava com confirmação; ferramentas = rotinas declaradas; modelo por conector; tudo auditado | implementada |
| 053 | [Regressão automática do cliente](053-customer-regression/spec.md) | Trilhas do próprio cliente (gravadas fazendo) rodadas na instância de testes a cada atualização; relatório de impacto; liberação só com ensaio aceito | especificada |
| 054 | [Chão de fábrica e rastreabilidade](054-shop-floor-traceability/spec.md) | Número de série e genealogia, coleta de bancadas e máquinas, qualidade automática, recall em segundos, painel em tempo real | especificada |
| 055 | [Fechamento contínuo](055-continuous-close/spec.md) | Painel do fechamento com verificações automáticas diárias, fechar quando verde, pacote do período | especificada |
| 056 | [Ensaio universal](056-universal-rehearsal/spec.md) | Toda rotina que grava pode ser ensaiada pelo núcleo, com efeitos externos retidos e resumo legível do efeito | implementada (falta assistente e regras) |
| 057 | [Central de suporte e parceiros](057-support-center/spec.md) | "Pedir ajuda" com contexto, pacote de diagnóstico mascarado, acesso de suporte pelo acesso emergencial, painel do parceiro | especificada |
| 058 | [Filiais sem internet](058-offline-branches/spec.md) | Nó de filial que opera desconectado e sincroniza sem duplicar | especificada (depende de decisão) |
| 059 | [Documentos fiscais eletrônicos](059-electronic-invoices/spec.md) | NF-e, NFC-e e NFS-e nacional a partir dos documentos e do motor de impostos; faturar e emitir num passo; contingência automática; numeração segura; notas de entrada pela distribuição da SEFAZ com confronto e manifestação; bateria de homologação pelos cenários da empresa; campos da reforma | especificada (revisada em 26/11/2026; depende das specs 072 e 049 fase 2) |
| 060 | [Aplicativo no celular](060-mobile-app/spec.md) | PWA instalável: aprovações, OS de campo com foto e assinatura, recebimento e contagem com câmera, notificações | especificada |
| 061 | [Implantação guiada](061-guided-onboarding/spec.md) | Assistente de implantação por perfil de negócio, modelos prontos, saldos iniciais conciliados, dados de demonstração, checklist de prontidão | especificada |
| 062 | [Erlang ao máximo](062-erlang-at-its-best/spec.md) | Supervisão por subsistema, eventos no lugar de ciclos (no nó, entre nós e no navegador), isolamento por conector e por fluxo, temporizadores do Erlang, tela "Núcleo"; revisão de todos os subsistemas existentes; sempre medido, sem regressão | fases 1 e 2 implementadas (falta T-062-08b; fase 3 na fila) |
| 063 | [Vida útil do disco](063-disk-endurance/spec.md) | Orçamento de escrita por operação e com o sistema ocioso testado na bateria, painel "Disco" com projeção de desgaste do SSD, alertas de salto de escrita, ajustes do banco e temporários em memória; revisão de todas as funcionalidades | fase 1 implementada |
| 064 | [Portão de qualidade dos programas](064-program-quality-gate/spec.md) | Inspeção automática (segurança, desempenho, robustez, padrões, experiência, disco) enquanto se digita; regras configuráveis, linha de base e isenções aprovadas; testes e cobertura dos programas; desempenho comparado com a versão anterior; portão obrigatório e assinado no transporte para a produção | implementada (fases 1 e 2) |
| 065 | [Valores da empresa](065-company-values/spec.md) | Valores nomeados, tipados e com vigência (simples, referência a cadastro, lista, seleção) que rotinas, SQL, variantes, agendamentos, regras, esteiras e impostos leem pelo nome; por ambiente e filial; atualizados por rotinas; em memória em cada nó; onde é usado, quatro olhos e transporte | implementada (falta T-065-11b) |
| 066 | [Núcleo aberto (AGPL-3.0) e edição comercial](066-open-core/spec.md) | Código aberto em AGPL-3.0 com exceção para os programas do cliente, licença comercial com CLA, núcleo sem trava, assinatura para módulos premium (repositório privado), pacotes fiscais oficiais e suporte; SaaS do fornecedor; publicação do repositório | fase 1 implementada (LICENSE, NOTICE, SPDX, CLA, licenças e credenciais nos pull requests); falta publicar |
| 067 | [Uso simulado contínuo](067-usage-simulation/spec.md) | Usuários sintéticos (personas com acesso real) percorrendo esteiras inteiras com variação e semente, pela API e pelas telas, numa rotina agendada fora da produção; oráculos de automação, contas, usabilidade e desempenho; relatório com tendência; achado vira trilha de regressão | implementada (fase 1) |
| 068 | [Mudanças vigiadas](068-change-watch/spec.md) | Gatilho "alterado" nas regras: qualquer campo do catálogo de cadastros e documentos vira evento; custo zero de escrita sem regra, cadastros sobre o histórico existente, um evento por documento e transação, lote agrupado; dono e escopo de dados, campo sigiloso nunca sai, dado pessoal só para conector autorizado; "Avisar quando mudar" | especificada |
| 069 | [Cenários "e se…"](069-what-if-scenarios/spec.md) | Projeção base de caixa, operação e resultado; cenários com choques (câmbio, atraso de fornecedor ou cliente, prazos, volume, capacidade, imposto) propagados em cascata pelas regras reais em simulação, sem gravar; comparação, caminho do efeito, ações sugeridas; pergunta pelo assistente; cenários vigiados | especificada |
| 070 | [Legislação vigiada](070-legislation-watch/spec.md) | Fontes oficiais como catálogo, filtragem pelo perfil fiscal, proposta de regra como rascunho com casos de teste e impacto por cenário, quatro olhos, vigência da norma, conciliação com o pacote oficial; texto coletado nunca é instrução | especificada (depende da 049 fase 2) |
| 071 | [Carbono e fornecedores certificados](071-carbon-and-certifications/spec.md) | Certificações do fornecedor com validade, bloqueio de compra no banco com exceção por quatro olhos, renovação pelo portal, listas públicas por conector; fatores de emissão como dado, emissão no fato até lote e série, por escopo, gravada uma vez | especificada |
| 072 | [Canal com os órgãos de governo](072-government-channel/spec.md) | Serviço único de assinatura e transmissão: certificado A1 no cofre e com validade vigiada, leiautes e serviços em pacotes, validação local que aponta a origem, fila idempotente que consulta antes de repetir, estado dos serviços, ambientes de teste, bateria de homologação, guarda legal, painel "Governo" | especificada |
| 073 | [Folha de pagamento](073-payroll/spec.md) | CLT, pró-labore, autônomo, estágio; cadastro único do colaborador; rubricas e tabelas como dado com casos de teste; férias, 13º, rescisão; fechamento guiado com prévia e quatro olhos; lançamentos, títulos, pagamento bancário, custo real da hora nos projetos e fator R; portal do colaborador; sigilo | especificada |
| 074 | [eSocial, DCTFWeb e FGTS Digital](074-esocial/spec.md) | Eventos gerados dos fatos pelas mudanças vigiadas, ordem e prazos, leiaute em pacote, totalizadores conciliados com a folha, DCTFWeb e guia do FGTS como títulos conferidos, retificações seguras, homologação na produção restrita | especificada |
| 075 | [Obrigações acessórias e agenda fiscal](075-tax-obligations/spec.md) | Catálogo de obrigações como dado, agenda da empresa com preparação antecipada, livros e apurações derivados com conciliação contábil, guias como títulos, entrega por serviço ou programa oficial com recibo conferido, retificação pelo impacto, Simples sem digitação, acesso do contador | especificada |
| 076 | [Funcionalidades por perfil](076-feature-profile/spec.md) | Catálogo de funcionalidades mais fino que os módulos, com dependências e efeitos; perfis de negócio editáveis; desligado some de menus, telas, campos, rotinas e regras sem perder dados (`FEATURE_OFF`); ligar guiado com o que falta; desligar com ensaio do impacto e recusa; por empresa, filial e ambiente; estado em memória, nada desligado roda; rastreador por perfil | especificada |

## Glossário

| Termo (docs) | Identificador (código) | Significado |
|--------------|------------------------|-------------|
| Programa | `program` | Código Python versionado no banco, executado pelo núcleo. |
| Programa exposto | `exposed = true` | Programa chamável de fora do ERP (JSON-RPC). |
| Biblioteca | `kind = 'library'` | Programa importável por outros (`import ana_lib.<nome>`). |
| Valor da empresa | `company_value` | Valor de negócio com nome, tipo e vigência, mantido pela empresa e lido pelas rotinas pelo nome (`ana.value`), sem mudar código (spec 065). |
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
