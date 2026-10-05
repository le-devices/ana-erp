Você trabalha no projeto ANA ERP em /home/andre/ana-erp: um ERP com núcleo Erlang/OTP, PostgreSQL 16 (Citus colunar) e programas de negócio em Python executados e depurados dentro do próprio ERP. Seu objetivo é implementar **a próxima spec pendente** — uma por execução — seguindo Spec Driven Development, e deixar tudo testado.

## Regras do projeto (obrigatórias)
- SDD: leia `specs/README.md`, `specs/000-constitution.md` e a spec alvo (`spec.md`, `plan.md`, `tasks.md`). Se não houver `plan.md`, escreva-o antes do código. Se a implementação exigir mudar uma decisão, atualize primeiro a spec/plan e depois o código. Testes citam os IDs dos critérios (ex.: `test_ca_021_01_...`).
- Nunca use nomenclatura SAP (ABAP, BAPI, RFC, IDoc, transaction code, LUW, mandante/client, destination, business partner, material como tipo de item, HANA etc.), em nenhum idioma.
- Todo o código em inglês (identificadores, SQL, JSON, rotas, códigos de erro, comentários). Textos de tela e mensagens ao usuário em português. Em Erlang, todo literal binário com acento leva `/utf8` (`<<"ação"/utf8>>`) e textos formatados usam `unicode:characters_to_binary(io_lib:format(...))`.
- Prioridades: segurança, robustez e performance (constituição P10–P12); operação 24/7 sem que falhas derrubem o sistema; produto licenciável para vários clientes (P13): nada específico de cliente fixo no código.
- Toda execução tem dono (constituição P14): qualquer programa, tarefa interna, parte paralela ou chamada nova roda em nome de um usuário ativo (pessoa ou robô); o que o ERP dispara sozinho usa o robô `system` via `ana_task:run/4` ou `ana_task:system_user()`.
- Rastreabilidade (spec 024) e disco (P15, spec 025): toda ação nova deve aparecer na auditoria/trilha e respeitar a retenção; não grave o que não mudou, prefira lotes e tabelas particionadas para dados de alto volume.
- Migrações novas em `priv/migrations/NNN_*.sql` (próximo número livre); nunca edite migrações já existentes. Programas-semente em `priv/programs/<namespace>.<name>.py` com cabeçalho `# ana:description`, `# ana:exposed`, `# ana:command`, `# ana:kind`, `# ana:role`.
- Interface (priv/www) segue a spec 020: fluxo de trabalho coerente e fluido (cada tela leva ao próximo passo do processo), coisas relacionadas juntas; operador em Operação, desenvolvedor em Desenvolvimento (tudo de um programa em abas do programa), administrador em Administração (grupos Pessoas e acesso / Sistema / Operação do sistema). Sem dependências externas; conteúdo dinâmico só via `textContent`.

## Ordem das pendências
1. 021 — consultoria: projetos de clientes de ponta a ponta (`specs/021-consulting-projects`) — o caso do dono do produto
2. 022 — execução paralela (`specs/022-parallel-execution`)
3. 023 — alta disponibilidade e testes de caos (`specs/023-high-availability`) — implementada; a tarefa pendente T-023-09 é o item 5
4. 019 — observabilidade (`specs/019-observability`) — implementada; T-019-08b e T-019-09b ficam para o fim da fila
5. 023 — T-023-09: troca real de primário com cluster PostgreSQL local — implementada
6. 013 — cadeia de suprimentos (`specs/013-supply-chain`)
7. 017 — hub de integrações (`specs/017-integration-hub`)
8. 016 — repositório de arquivos (`specs/016-file-repository`)
9. 014 — produção e capacidade (`specs/014-production-planning`)
10. 015 — logística e campo (`specs/015-logistics-field-service`)
11. 010 — API pública (`specs/010-public-api`)
12. 009 — licenciamento (`specs/009-licensing`): é rascunho com decisões em aberto; NÃO implemente — liste as decisões necessárias no relatório e pare.
13. 020 — tarefas restantes da arquitetura da informação: próxima ação sugerida, fluxos guiados, continuidade (T-020-09..11) e auditoria de acessibilidade (T-020-07). Itens de fluxo podem ser adiantados quando a spec em andamento precisar deles.

Escolha o **primeiro item da lista cuja `tasks.md` ainda tenha tarefas `[ ]`** (exceções: a T-023-09 é o item 5; as T-019-08b e T-019-09b ficam para depois de todos os outros itens). Se tudo estiver `[x]`, apenas rode as suítes e relate.

## Passos
1. `cd /home/andre/ana-erp && git status` — se houver alterações não commitadas que não são suas, não as descarte; trabalhe por cima e relate.
2. Suba o ambiente: `docker compose up -d --build` e aguarde `curl -s localhost:8080/health` responder `"status":"ok"`.
3. Implemente a spec escolhida: migração, módulos Erlang (`src/`), programas Python, rotas HTTP, telas, e testes de integração em `tests/integration/test_integration.py` (crie programas só com prefixo `test.` — o teste de módulo os remove ao final).
4. Rode e deixe verde:
   - `docker run --rm -v $PWD:/app -w /app erlang:27 rebar3 compile` (sem avisos; `warnings_as_errors` está ligado)
   - `docker run --rm -v $PWD:/app -v ana-plt:/root/.cache/rebar3 -w /app erlang:27 sh -c 'rebar3 eunit && rebar3 dialyzer'`
   - `python3 -m unittest discover -s tests/runtime`
   - `python3 -m unittest discover -s tests/integration` (rode duas vezes: deve repetir sem falhas)
   - `docker run --rm --network host -v $PWD/tests/studio:/t -w /t node:22-alpine sh -c "npm i --silent --no-save jsdom@24 >/dev/null 2>&1 && node smoke.mjs"`
   - `tests/cluster/run.sh` (dois nós: agendamento exatamente uma vez, troca de líder, distribuição Erlang)
   - `tests/chaos/run.sh` (dois nós + balanceador: falhas, queda de nó, desligamento gracioso, rolling, banco, restauração)
   - `tests/pg_ha/run.sh` (PostgreSQL primário + réplica: troca real de primário)
5. Marque `[x]` em `tasks.md` só o que estiver implementado **e** testado; atualize a coluna "Situação" em `specs/README.md` e a seção "Situação das specs" do `README.md`.
6. Versionamento (gitflow, ver README): crie `feature/NNN-assunto` a partir de `dev`, faça os commits da spec nela (assinados quando a chave GPG estiver liberada; se estiver bloqueada, o dono autorizou commits sem assinatura com `git -c commit.gpgsign=false commit`, sem alterar a configuração global) e, com tudo verde, integre em `dev` (merge sem fast-forward). Nunca commite nem integre em `qa` ou `master`, e não faça push, sem pedido explícito. Não apague volumes/arquivos fora do que você mesmo criou nesta execução.

## Relatório final (em português)
- Qual spec foi trabalhada; tarefas concluídas e pendentes.
- Resultado de cada suíte (números).
- Decisões tomadas que alteraram a spec, e qualquer pergunta que exija decisão do dono do produto.
- Próxima spec da fila.
