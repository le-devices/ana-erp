# 063 — Tarefas

Fase 1 — medir, vigiar e impedir regressão
- [x] T-063-01 Medição de escrita por operação e ocioso; orçamento versionado e teste na bateria (RF-063-01, D1, CA-063-01)
- [x] T-063-02 Painel "Disco" com projeção de desgaste (RF-063-02, D3, CA-063-02, 03)
- [x] T-063-03 Métricas de escrita nas regras de alerta, com tabela e programa responsáveis (RF-063-03, D4, CA-063-04)
- [x] T-063-04 Ajustes do banco, temporários em memória e logs na instalação padrão (RF-063-05, D6–D8)
- [x] T-063-05 Saúde do disco pelo ana-ctl e sugestões de configuração do servidor (RF-063-04, D5)

Fase 2 — revisão de tudo o que já existe (D9, RF-063-06, CA-063-05)
- [ ] T-063-06 Ciclos ociosos: saúde, alertas, verificações, agendamento, processos e esteiras, integração, estatísticas de SQL
- [ ] T-063-07 Operação: execuções, API pública, sessões e preferências de tela, painéis, e-mail, arquivos e uploads
- [ ] T-063-08 Dados e manutenção: analítico, retenção e expurgos, índices pouco usados, cópias e arquivo de WAL

## Fase 1 — o que foi medido (7/11/2026)
- Orçamento versionado em `priv/disk_budget.json` (bytes de WAL): ocioso ~229 KB/h; rotina curta ~5 KB;
  criar pedido ~21 KB; faturar ~24 KB; chamada da API ~5 KB; importar 1.000 cadastros ~2,2 MB; ciclo de alertas ~0.
  Teste `TestDiskEndurance` (tolerância 50 %, piso de 8 KB; ocioso 200 %).
- Achado de passagem, corrigido: as estatísticas de SQL contavam zero linhas para UPDATE/DELETE sem RETURNING
  (`ana_execution:note_sql`); agora contam as linhas alteradas — o que também dá nome ao programa num salto de escrita.
- Para a fase 2 (T-063-06..08), vistos na medição: `task_run`, `perf_sample` e `metric_sample` são o que o
  ocioso grava; `files.blob` é atualizado logo após a partida; o banco de desenvolvimento acumulou ~31 GB de escrita
  em tabelas temporárias de sessão (`pg_stat_io`, temp relation) — descobrir quem cria; 700 checkpoints forçados
  contra 2.979 programados (testes e restaurações); `archive_timeout=300` na produção copia um segmento de 16 MB a
  cada 5 min com escrita (decisão de RPO: só sugerido no painel e no guia).

## Achados da fase 1, resolvidos antes da fase 2 (14/11/2026, item 7a da fila)
Escrita medida antes e depois em cada um (CA-063-05):
- (a) `ana_task`: uma tarefa curta grava uma única linha, já terminada (era INSERT "em andamento" + UPDATE); a
  linha "em andamento" só aparece se a tarefa passar de 2 s. Uma rodada periódica do analítico sem nada a fazer
  não grava nada (`{skip, _}`). Teste: `test_ca_063_05_short_task_written_once_and_idle_task_not_at_all`
  (UPDATEs em `task_run` por tarefa curta: 1 → 0).
- (b) `ana_datacopy`: a carga da cópia não passa mais por tabela de preparação — vai direto do arquivo para cada
  tabela, em lotes de 500. Só fica de lado o que precisa esperar (ciclo entre tabelas, linha que aponta para outra
  ainda não carregada fora do lote). Ensaio de 1,32 milhão de linhas (110 tabelas): gravação em tabela temporária
  **440 MB → 0**, WAL 665 → 660 MB, tempo 80 s → 86 s (variação da máquina). Para isso:
  - a conferência de referência compara no tipo da coluna (por texto não usava o índice);
  - os planos guardados do banco são descartados cada vez que a tabela dobra de tamanho (o plano feito com a tabela
    recém-esvaziada varria a tabela inteira a cada linha: 165 s);
  - tabelas que apontam para si mesmas saem da exportação em ordem de chave.
  Teste: `test_ca_034_05` exige menos de 2 MB de escrita temporária no ensaio.
- (c) `files.blob`: a verificação de integridade (RNF-016-03) relia e regravava 20 arquivos a cada 15 min, os
  mesmos quando havia poucos — e, com 24 mil arquivos, nunca alcançava todos. Agora cada arquivo é relido no máximo
  uma vez por semana, a amostra cresce o bastante para cobrir todos na semana, e os aprovados são marcados num só
  comando; rodada sem nada vencido não grava. Teste: `test_rnf_016_03_integrity_rechecked_weekly_not_every_run`.
- (d) Checkpoints forçados: os 700 eram do contador acumulado desde 2/10 (antes de T-063-04); desde 7/11, 16 forçados,
  todos em cargas grandes (bateria e ensaios de cópia), que é o esperado com `max_wal_size=2GB`. A sugestão do painel
  "Disco" olhava o acumulado e acusaria para sempre uma configuração já corrigida: agora olha os últimos 7 dias
  (`ana_disk:recent_checkpoints/1`, eunit `checkpoint_advice_test_`).
- (e) `archive_timeout=300` na produção: mantido; decisão de perda máxima aceitável (RPO) com o dono do produto.
- De passagem: os testes de cluster e caos aceitam portas pelo ambiente (`ANA_PORT`, `ANA2_PORT`, `ANA_LB_PORT`),
  para rodar quando outro serviço da máquina ocupa 8080/8081/8090.
