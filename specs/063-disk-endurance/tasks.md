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
