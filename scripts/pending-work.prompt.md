Você trabalha no projeto ANA ERP em /home/andre/ana-erp: um ERP com núcleo Erlang/OTP, PostgreSQL 16 (Citus colunar) e programas de negócio em Python executados e depurados dentro do próprio ERP. Seu objetivo é implementar **a próxima spec pendente** — uma por execução — seguindo Spec Driven Development, e deixar tudo testado.

## Regras do projeto (obrigatórias)
- SDD: leia `specs/README.md`, `specs/000-constitution.md` e a spec alvo (`spec.md`, `plan.md`, `tasks.md`). Se não houver `plan.md`, escreva-o antes do código. Se a implementação exigir mudar uma decisão, atualize primeiro a spec/plan e depois o código. Testes citam os IDs dos critérios (ex.: `test_ca_021_01_...`).
- Nunca use nomenclatura SAP (ABAP, BAPI, RFC, IDoc, transaction code, LUW, mandante/client, destination, business partner, material como tipo de item, HANA etc.), em nenhum idioma.
- Todo o código em inglês (identificadores, SQL, JSON, rotas, códigos de erro, comentários). Textos de tela e mensagens ao usuário em português. Em Erlang, todo literal binário com acento leva `/utf8` (`<<"ação"/utf8>>`) e textos formatados usam `unicode:characters_to_binary(io_lib:format(...))`.
- Prioridades: segurança, robustez e performance (constituição P10–P12); operação 24/7 sem que falhas derrubem o sistema; produto licenciável para vários clientes (P13): nada específico de cliente fixo no código.
- Toda execução tem dono (constituição P14): qualquer programa, tarefa interna, parte paralela ou chamada nova roda em nome de um usuário ativo (pessoa ou robô); o que o ERP dispara sozinho usa o robô `system` via `ana_task:run/4` ou `ana_task:system_user()`.
- Rastreabilidade (spec 024) e disco (P15, spec 025): toda ação nova deve aparecer na auditoria/trilha e respeitar a retenção; não grave o que não mudou, prefira lotes e tabelas particionadas para dados de alto volume.
- Migrações novas em `priv/migrations/NNN_*.sql` (próximo número livre); nunca edite migrações já existentes. Programas-semente em `priv/programs/<namespace>.<name>.py` com cabeçalho `# ana:description`, `# ana:exposed`, `# ana:command`, `# ana:kind`, `# ana:role`. Alterar uma semente existente não muda o programa instalado: a mudança vira "atualização do produto" (spec 028) — aceite-a pela API `POST /api/admin/product-updates/<nome>/accept` (ou `accept-unmodified`) no ambiente de teste antes de rodar as suítes.
- Interface (priv/www) segue a spec 020: fluxo de trabalho coerente e fluido (cada tela leva ao próximo passo do processo), coisas relacionadas juntas; operador em Operação, desenvolvedor em Desenvolvimento (tudo de um programa em abas do programa), administrador em Administração (grupos Pessoas e acesso / Sistema / Operação do sistema). Sem dependências externas; conteúdo dinâmico só via `textContent`.

## Ordem das pendências
1. 021 — consultoria: projetos de clientes de ponta a ponta (`specs/021-consulting-projects`) — o caso do dono do produto
2. 022 — execução paralela (`specs/022-parallel-execution`)
3. 023 — alta disponibilidade e testes de caos (`specs/023-high-availability`) — implementada; a tarefa pendente T-023-09 é o item 5
4. 019 — observabilidade (`specs/019-observability`) — implementada; T-019-08b e T-019-09b ficam para o fim da fila
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
16. 010 — API pública (`specs/010-public-api`) — implementada; T-010-06b, 10b, 11b, 12b e 14b ficam para o fim da fila
16a. 038 — processos integrados e conciliação automática (`specs/038-integrated-processes`) — implementada (fases 1–4)
16b. 039 — BPM: modelagem, simulação e execução de processos (`specs/039-bpm`) — implementada (inclui T-039-17b); T-039-16b fica para o fim da fila
16c. 040 — dados mestres padronizados (`specs/040-master-data`) — implementada; T-040-10b, T-040-11b, T-039-16b e T-039-17b ficam para o fim da fila
17. 009 — licenciamento (`specs/009-licensing`): implementada (fases 1–3); a dimensão empresa da permissão por dado aguarda documentos por empresa.
18. 020 — arquitetura da informação (`specs/020-information-architecture`) — implementada até RF-020-12; padrões de telas de produtividade (T-020-12..17: barra de tabela com variantes, painéis com estado, construtor de condições, simulação ao lado, grade de planejamento com gráfico) implementados; organização por áreas e categorias (T-020-18..21) implementada.
18a. 041 — atendimento do pedido conforme a política da empresa (`specs/041-sales-fulfillment-policy`) — especificada; T-041-01..08 a fazer.

Tarefas adiadas — ordem acordada com o dono do produto (out/2026), uma por vez: T-017-05b ✓ (extrato por pasta OFX/CNAB 240 ou API do banco), T-039-17b ✓ (início de processo por agendamento e por mensagem), T-035-05b ✓ (marcos, faturas de projeto, recebimentos e notas no visualizador), T-040-11b ✓ (rotinas de cadastro abrem a ficha padrão), E-04 da spec 042 ✓ (totais sobre listas cortadas; folha de contagem completa), T-019-08b, T-010-06b, T-037-06b, T-033-09b, T-040-10b, T-039-16b; por último as que dependem de infraestrutura ou decisão (S3, antivírus, registro de imagem, OpenTelemetry, mTLS, SFTP/e-mail, pacotes de conectores, transporte T-034-07b..09b, API T-010-10b..14b, T-032-06b).

Escolha o **primeiro item da lista cuja `tasks.md` ainda tenha tarefas `[ ]`** (exceções: a T-023-09 é o item 5; as T-019-08b, T-019-09b, T-017-02b, T-017-02c, T-017-08b, T-016-02b, T-016-04b, T-033-09b, T-034-07b, T-034-08b, T-034-09b, T-032-06b, T-035-05b, T-036-07b, T-036-08b, T-037-06b, T-010-06b, T-010-10b, T-010-11b, T-010-12b, T-010-14b, T-040-10b, T-040-11b, T-039-16b e T-039-17b ficam para depois de todos os outros itens). Se tudo estiver `[x]`, apenas rode as suítes e relate.
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
