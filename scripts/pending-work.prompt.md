Você trabalha no projeto ANA ERP em /home/andre/ana-erp: um ERP com núcleo Erlang/OTP, PostgreSQL 16 (Citus colunar) e programas de negócio em Python executados e depurados dentro do próprio ERP. Seu objetivo é implementar **a próxima spec pendente** — uma por execução — seguindo Spec Driven Development, e deixar tudo testado.

## Regras do projeto (obrigatórias)
- SDD: leia `specs/README.md`, `specs/000-constitution.md` e a spec alvo (`spec.md`, `plan.md`, `tasks.md`). Se não houver `plan.md`, escreva-o antes do código. Se a implementação exigir mudar uma decisão, atualize primeiro a spec/plan e depois o código. Testes citam os IDs dos critérios (ex.: `test_ca_021_01_...`).
- Nunca use nomenclatura SAP (ABAP, BAPI, RFC, IDoc, transaction code, LUW, mandante/client, destination, business partner, material como tipo de item, HANA etc.), em nenhum idioma.
- Todo o código em inglês (identificadores, SQL, JSON, rotas, códigos de erro, comentários). Textos de tela e mensagens ao usuário em português. Em Erlang, todo literal binário com acento leva `/utf8` (`<<"ação"/utf8>>`) e textos formatados usam `unicode:characters_to_binary(io_lib:format(...))`.
- Prioridades: segurança, robustez e performance (constituição P10–P12); operação 24/7 sem que falhas derrubem o sistema; produto licenciável para vários clientes (P13): nada específico de cliente fixo no código.
- Toda execução tem dono (constituição P14): qualquer programa, tarefa interna, parte paralela ou chamada nova roda em nome de um usuário ativo (pessoa ou robô); o que o ERP dispara sozinho usa o robô `system` via `ana_task:run/4` ou `ana_task:system_user()`.
- Vida útil do disco (P15, specs 025 e 063): toda funcionalidade nova ou alterada respeita o orçamento de escrita (bytes de WAL por operação e com o sistema ocioso, testados na bateria por TestDiskEndurance contra `priv/disk_budget.json`; uma operação nova típica ganha entrada no orçamento); ocioso não escreve; nada é regravado se não mudou.
- Rastreabilidade (spec 024) e disco (P15, spec 025): toda ação nova deve aparecer na auditoria/trilha e respeitar a retenção; não grave o que não mudou, prefira lotes e tabelas particionadas para dados de alto volume.
- Migrações novas em `priv/migrations/NNN_*.sql` (próximo número livre); nunca edite migrações já existentes. Programas-semente em `priv/programs/<namespace>.<name>.py` com cabeçalho `# ana:description`, `# ana:exposed`, `# ana:command`, `# ana:kind`, `# ana:role`. Alterar uma semente existente não muda o programa instalado: a mudança vira "atualização do produto" (spec 028) — aceite-a pela API `POST /api/admin/product-updates/<nome>/accept` (ou `accept-unmodified`) no ambiente de teste antes de rodar as suítes.
- Erlang ao máximo (constituição P20, spec 062): processos isolados, supervisão por subsistema, eventos em vez de consulta repetida e telas ao vivo onde isso deixar o ERP mais rápido, robusto ou vivo — nunca à custa de desempenho ou robustez; toda mudança assim traz medição antes e depois.
- Experiência premium e automação por padrão (constituição P18 e P19, specs 050 e 051) valem para **toda** tarefa: cada tela nova ou alterada passa no verificador da spec 050 (quando existir), tem próximo passo, estado vazio com ação, erro com orientação, atalhos, ensaio para o que grava e valores padrão pelo contexto; cada spec declara o que a pessoa deixa de fazer (o que vira automático, política ou sugestão).
- Interface (priv/www) segue a spec 020: fluxo de trabalho coerente e fluido (cada tela leva ao próximo passo do processo), coisas relacionadas juntas; operador em Operação, desenvolvedor em Desenvolvimento (tudo de um programa em abas do programa), administrador em Administração (grupos Pessoas e acesso / Sistema / Operação do sistema). Sem dependências externas; conteúdo dinâmico só via `textContent`.

## Ordem das pendências
1. 021 — consultoria: projetos de clientes de ponta a ponta (`specs/021-consulting-projects`) — o caso do dono do produto
2. 022 — execução paralela (`specs/022-parallel-execution`)
3. 023 — alta disponibilidade e testes de caos (`specs/023-high-availability`) — implementada; a tarefa pendente T-023-09 é o item 5
4. 019 — observabilidade (`specs/019-observability`) — implementada; T-019-08b ✓; T-019-09b fica para o fim da fila
5. 023 — T-023-09: troca real de primário com cluster PostgreSQL local — implementada
6. 013 — cadeia de suprimentos (`specs/013-supply-chain`) — implementada
7. 017 — hub de integrações (`specs/017-integration-hub`) — implementada; T-017-02b/02c/05b/08b ficam para o fim da fila
8. 016 — repositório de arquivos (`specs/016-file-repository`) — implementada; T-016-02b/04b ficam para o fim da fila
9. 014 — produção e capacidade (`specs/014-production-planning`) — implementada
10. 015 — logística e campo (`specs/015-logistics-field-service`) — implementada
11. 031 — condições de pagamento e crédito, usabilidade dos formulários (`specs/031-payment-terms-credit`) — implementada
12. 033 — verificações periódicas de segurança, bibliotecas/ativos vulneráveis, robustez e desempenho (`specs/033-periodic-checks`) — implementada; T-033-09b fica para o fim da fila
13. 034 — instância de desenvolvimento e testes: transporte seguro e sem parada para produção; cópia de dados reais de produção mascarados como massa de testes (`specs/034-dev-test-instance`) — implementada; T-034-07b, 08b e 09b ficam para o fim da fila
14. 030 — esteiras automáticas: venda → baixa de estoque → movimentação → faturamento → cobrança, e outras, com opção de passos automáticos (`specs/030-automated-flows`) — implementada (inclui T-030-06b)
15. 032 — distância aproximada empresa ↔ cliente por coordenadas (`specs/032-distances`) — implementada; T-032-06b fica para o fim da fila
15a. 035 — documentos navegáveis (`specs/035-document-navigation`) — implementada; T-035-05b fica para o fim da fila
15b. 036 — instalação pelo cliente, local e nuvem, com passos definidos (`specs/036-installation`) — implementada; T-036-07b e 08b ficam para o fim da fila
15c. 037 — documentos para clientes e fornecedores em PDF, download controlado (`specs/037-customer-documents`) — implementada; T-037-06b fica para o fim da fila
16. 010 — API pública (`specs/010-public-api`) — implementada; T-010-06b ✓; 10b, 11b, 12b e 14b ficam para o fim da fila
16a. 038 — processos integrados e conciliação automática (`specs/038-integrated-processes`) — implementada (fases 1–4)
16b. 039 — BPM: modelagem, simulação e execução de processos (`specs/039-bpm`) — implementada (inclui T-039-17b); T-039-16b fica para o fim da fila
16c. 040 — dados mestres padronizados (`specs/040-master-data`) — implementada; T-040-10b, T-040-11b, T-039-16b e T-039-17b ficam para o fim da fila
17. 009 — licenciamento (`specs/009-licensing`): implementada (fases 1–3); a dimensão empresa da permissão por dado aguarda documentos por empresa.
18. 020 — arquitetura da informação (`specs/020-information-architecture`) — implementada até RF-020-12; padrões de telas de produtividade (T-020-12..17: barra de tabela com variantes, painéis com estado, construtor de condições, simulação ao lado, grade de planejamento com gráfico) implementados; organização por áreas e categorias (T-020-18..21) implementada.
18a. 041 — atendimento do pedido conforme a política da empresa (`specs/041-sales-fulfillment-policy`) — especificada; T-041-01..08 a fazer.

Tarefas adiadas já concluídas (ordem acordada em out/2026): T-017-05b ✓, T-039-17b ✓, T-035-05b ✓, T-040-11b ✓, E-04 da spec 042 ✓, T-019-08b ✓ (regras de alerta e silêncios), T-010-06b ✓ (disjuntor por cliente da API pública).

**Fila atual — reorganizada em 07/11/2026 a pedido do dono do produto pelo critério comercial (experiência premium, automação, diferenciais de mercado); uma por vez, nesta ordem, e ela prevalece sobre a regra de escolha abaixo.** Nenhuma tarefa planejada antes saiu da fila:
1. ✓ 043 — cadastro fiscal de pessoas (falta T-043-02b, dígito da IE por UF, no fim da fila)
2. ✓ 044 — e-mail de saída por SMTP
3. ✓ T-037-06b — envio do link do documento por e-mail
4. ✓ T-033-09b — base OSV por conector e aviso por e-mail
5. ✓ 050 fase 1 — padrão de experiência que se verifica sozinho (T-050-01..04): tudo o que vier depois já nasce premium (`specs/050-premium-experience`)
6. ✓ 062 fases 1 e 2 (falta T-062-08b, no fim da fila) — Erlang ao máximo: supervisão por subsistema, eventos no lugar de ciclos, telas ao vivo, isolamento por conector, tela "Núcleo" — sempre medido, sem regressão (`specs/062-erlang-at-its-best`)
7. ✓ 063 fase 1 — vida útil do disco: medir a escrita, orçamento testado na bateria, painel "Disco" com projeção de desgaste, alertas (`specs/063-disk-endurance`)
7a. ✓ (a)–(e); (e) = janela de perda como parâmetro da instalação (padrão 5 min, decisão de 19/11/2026) — 063 achados da fase 1 (antecipados da fase 2 a pedido do dono do produto) — (a) `ana_task`: uma única gravação por tarefa curta (hoje INSERT ao começar + UPDATE ao terminar) e nada gravado quando a atualização periódica do analítico não tinha o que fazer; (b) `ana_datacopy`: a cópia de dados passa cada tabela por tabela temporária com `temp_buffers` de 8 MB → ~31 GB gravados no banco de desenvolvimento; medir antes/depois (pg_stat_io, temp relation) e carregar sem tabela intermediária ou com memória adequada; (c) `files.blob` atualizado logo após a partida; (d) checkpoints forçados (700 × 2.979); (e) `archive_timeout` da produção — decisão de RPO do dono do produto. Cada um com a escrita antes e depois (CA-063-05)
8. ✓ 049 fase 1 (faltam T-049-07b/07c, no fim da fila) — motor de impostos: motor, vigência, fórmulas, casos de teste, ISS e retenções e **Simples Nacional com fator R** (T-049-01..07, 06b; D10 de 19/11/2026: o caso de referência é empresa do Simples) — antecipada: reforma tributária (`specs/049-tax-engine`)
9. ✓ 049 fase 3 (faltam T-049-09b, alíquotas oficiais do Senado, e 09c, no fim da fila) — CBS, IBS e Imposto Seletivo na transição (T-049-09) — 2027 já tem CBS cheia
10. ✓ 064 fase 1 — portão de qualidade dos programas: inspeção no editor, regras e isenções, portão assinado no transporte para a produção (`specs/064-program-quality-gate`)
11. ✓ 056 — ensaio universal: toda rotina que grava pode ser ensaiada (`specs/056-universal-rehearsal`)
11a. ✓ 065 fase 1 — valores da empresa: valores nomeados com vigência, leitura por programas e SQL, expressões dinâmicas num só lugar, em memória em cada nó (`specs/065-company-values`) — antes da 045, que os usa
12. ✓ 045 — variantes de execução (`specs/045-execution-variants`)
12a. ✓ 065 fase 2 — valores da empresa nas variantes, agendamentos, regras, esteiras e impostos; valores mantidos por rotinas; onde é usado; transporte (T-065-07..11)
13. ✓ 050 fase 2 — paleta de comandos, desfazer, valores padrão por contexto, câmera (T-050-05..08)
13a. ✓ 066 fase 1 — publicar o repositório em AGPL-3.0: LICENSE/NOTICE, SPDX, CONTRIBUTING/SECURITY, CLA, licenças das dependências e segredos na bateria (T-066-01..06; a publicação em si é ação do dono do produto). Fases 2 e 3 (núcleo sem trava, assinatura, premium, pacotes fiscais oficiais) entram depois na fila (`specs/066-open-core`)
14. ✓ 048 — painel inicial (`specs/048-home-panel`)
15. ✓ 052 — assistente que executa com segurança (`specs/052-safe-assistant`)
16. ✓ 064 fase 2 — testes dos programas e cobertura, desempenho comparado com a versão anterior, falhas ligadas à versão, tela "Qualidade" com o assistente (T-064-06..09)
16a. ✓ 067 fase 1 — uso simulado contínuo: personas robô percorrendo esteiras inteiras com variação, oráculos de automação e de contas, rotina agendada fora da produção (T-067-01..05 e 05b, com o workflow noturno do GitHub Actions; antecipada para logo depois da 064 fase 2, como rede de segurança das automações, em 21/11/2026; pedido do dono do produto em 21/11/2026). Fase 2 (telas, perfil real, trilhas) logo depois da 050 fase 3
16b. ✓ Correções achadas em 22/11/2026 (antes da 051): (1) varredura das esteiras: `flow.document_bills` faz leitura completa de `finance.bill` (LIKE com parâmetro) para cada etapa à espera, a cada 30 s — com ~1.500 etapas à espera mantém uma CPU ocupada sem parar; índice por faixa com COLLATE "C", varrer só documentos que mudaram e teste de tempo e de SQL na bateria (`fix/flow-sweep-index`); (2) testes de integração com a data de negócio do ANA em vez da data do executor (UTC), que falham entre 21h e 24h de Brasília (`fix/business-date-in-tests`, começada em 22/11/2026)
17. ✓ 051 — automação por padrão (`specs/051-automation-by-default`); T-051-06 vai com a 050 fase 3; T-051-04b (sequência e correção repetidas) depende da spec 046
18. ✓ 050 fase 3 — auditoria de experiência de todas as áreas (T-050-09..16), junto com a auditoria de automação (T-051-06)
18a. 068 — mudanças vigiadas: gatilho "alterado" em cadastros e documentos, com custo de escrita, desempenho e segurança medidos (`specs/068-change-watch`; plan.md primeiro, com as medições)
18b. 069 — cenários "e se…": projeção base e cenários em cascata (`specs/069-what-if-scenarios`)
19. 062 fase 3 — revisão de todos os subsistemas já implementados com o critério P20 (T-062-10..13)
20. 063 fase 2 — revisão de escrita desnecessária em todas as funcionalidades já implementadas (T-063-06..08)
21. 049 fase 2 — ICMS (ST, DIFAL, FCP), IPI, PIS/COFINS, Simples (T-049-08)
21a. 070 — legislação vigiada (`specs/070-legislation-watch`), depois da 049 fase 2
21b. 071 — fornecedores certificados (fase 1) e carbono (fase 2) (`specs/071-carbon-and-certifications`)
21c. 072 — canal com os órgãos de governo (`specs/072-government-channel`): certificado A1 (perguntar ao dono por um certificado de teste), assinatura, transmissão, simulador local dos serviços do governo para o CI
21d. 059 — documentos fiscais eletrônicos (`specs/059-electronic-invoices`): NFS-e nacional primeiro; NF-e e NFC-e depois da 049 fase 2
21e. 073 — folha de pagamento, fase 1 (`specs/073-payroll`); casos de teste conferidos por um especialista antes da primeira instalação com empregados
21f. 074 — eSocial, DCTFWeb e FGTS Digital (`specs/074-esocial`)
21g. 075 — obrigações acessórias e agenda fiscal, fase 1 Simples Nacional (`specs/075-tax-obligations`)
22. 061 — implantação guiada (`specs/061-guided-onboarding`)
23. 053 — regressão automática dos processos do cliente (`specs/053-customer-regression`)
24. 055 — fechamento contínuo (`specs/055-continuous-close`)
25. 046 — diagnósticos de programas (`specs/046-diagnostics`)
26. 047 — acesso emergencial e depuração em produção (`specs/047-emergency-access-debug`)
27. 057 — central de suporte (T-057-01..03) (`specs/057-support-center`)
28. 054 — chão de fábrica, bancada e rastreabilidade por número de série (`specs/054-shop-floor-traceability`)
29. 060 — aplicativo no celular (`specs/060-mobile-app`)
30. (059 foi para o item 21d)
31. T-040-10b — importação em lote rápida de cadastros
32. T-039-16b — editor BPM: arrastar da paleta, alinhar e distribuir
33. Por último, as que dependem de infraestrutura ou decisão: filiais sem internet (058), painel do parceiro (T-057-04b), MQTT (T-054-07b), S3 (T-016-02b, T-036-07b), antivírus (T-016-04b), registro de imagem (T-036-08b), OpenTelemetry (T-019-09b), mTLS (T-017-02c), SFTP/pasta/e-mail de entrada (T-017-02b), pacotes de conectores (T-017-08b), transporte (T-034-07b..09b), API (T-010-10b..14b; a 14b exige decisão), geocodificador simulado (T-032-06b), dígito verificador da inscrição estadual por UF (T-043-02b), temporizadores do Erlang para prazos do BPM (T-062-08b).

Fora da fila atual acima, escolha o **primeiro item da lista cuja `tasks.md` ainda tenha tarefas `[ ]`** (exceções: a T-023-09 é o item 5; as T-019-08b, T-019-09b, T-017-02b, T-017-02c, T-017-08b, T-016-02b, T-016-04b, T-033-09b, T-034-07b, T-034-08b, T-034-09b, T-032-06b, T-035-05b, T-036-07b, T-036-08b, T-037-06b, T-010-06b, T-010-10b, T-010-11b, T-010-12b, T-010-14b, T-040-10b, T-040-11b, T-039-16b e T-039-17b ficam para depois de todos os outros itens). Se tudo estiver `[x]`, apenas rode as suítes e relate.
19. 041 — atendimento do pedido de venda conforme a política da empresa (`specs/041-sales-fulfillment-policy`) — implementada (T-041-01..08).
20. Vistoria das trilhas de processos de negócio (`specs/042-process-trail-audit`) — vistoria, correções (A-01..A-04, M-01..M-02, B-01..B-05, E-01..E-03) e suíte `make teste-trilhas` concluídas em 31/10/2026. Escopo original: percorrer de ponta a ponta venda, compra, produção, serviço em campo, projetos e financeiro procurando falhas (passos sem ligação, documentos que não se encadeiam, estados sem saída, reconciliação manual) e listar o que corrigir antes de corrigir.

## Passos
1. `cd /home/andre/ana-erp && git status` — se houver alterações não commitadas que não são suas, não as descarte; trabalhe por cima e relate.
2. Suba o ambiente: `docker compose up -d --build` e aguarde `curl -s localhost:8080/health` responder `"status":"ok"`.
3. Implemente a spec escolhida: migração, módulos Erlang (`src/`), programas Python, rotas HTTP, telas, e testes de integração em `tests/integration/test_integration.py` (crie programas só com prefixo `test.` — o teste de módulo os remove ao final).
4. Rode e deixe verde:
   - `docker run --rm -v $PWD:/app -w /app erlang:27 rebar3 compile` (sem avisos; `warnings_as_errors` está ligado)
   - `docker run --rm -v $PWD:/app -v ana-plt:/root/.cache/rebar3 -w /app erlang:27 sh -c 'rebar3 eunit && rebar3 dialyzer'`
   - `python3 -m unittest discover -s tests/runtime`
   - `python3 -m unittest discover -s tests/integration` (rode duas vezes: deve repetir sem falhas)
   - `python3 -m unittest discover -s tests/trails` (trilhas de processo de ponta a ponta: conciliações iguais antes e depois)
   - `docker run --rm --network host -v $PWD/tests/studio:/t -w /t node:22-alpine sh -c "npm i --silent --no-save jsdom@24 >/dev/null 2>&1 && node smoke.mjs"`
   - `tests/cluster/run.sh` (dois nós: agendamento exatamente uma vez, troca de líder, distribuição Erlang)
   - `tests/chaos/run.sh` (dois nós + balanceador: falhas, queda de nó, desligamento gracioso, rolling, banco, restauração)
   - `tests/pg_ha/run.sh` (PostgreSQL primário + réplica: troca real de primário)
   - `tests/install/run.sh` (instalação de produção isolada: instala, atualiza sem parar, desinstala)
5. Marque `[x]` em `tasks.md` só o que estiver implementado **e** testado; atualize a coluna "Situação" em `specs/README.md` e a seção "Situação das specs" do `README.md`.
6. Versionamento (gitflow, ver README): crie `feature/NNN-assunto` a partir de `dev`, faça os commits da spec nela (assinados quando a chave GPG estiver liberada; se estiver bloqueada, o dono autorizou commits sem assinatura com `git -c commit.gpgsign=false commit`, sem alterar a configuração global) e, com tudo verde, integre em `dev` (merge sem fast-forward). Nunca commite nem integre em `qa` ou `master`, e não faça push, sem pedido explícito. Não apague volumes/arquivos fora do que você mesmo criou nesta execução.

## Relatório final (em português)
- Qual spec foi trabalhada; tarefas concluídas e pendentes.
- Resultado de cada suíte (números).
- Decisões tomadas que alteraram a spec, e qualquer pergunta que exija decisão do dono do produto.
- Próxima spec da fila.
