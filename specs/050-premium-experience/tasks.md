# 050 — Tarefas

Fase 1 — padrão que se verifica sozinho (vale para tudo o que vier depois)
- [x] T-050-01 Catálogo de padrões e página "Padrões" (RF-050-01, D1)
- [x] T-050-02 Verificador automático de telas nos testes do Estúdio (RF-050-02, CA-050-01)
- [x] T-050-03 Medição e orçamento de desempenho da interface; apontamento nas Verificações (RF-050-03, RNF-050-01, D2)
- [x] T-050-04 Catálogo de mensagens de erro com causa e ação (RF-050-07, CA-050-04)

Fase 2 — recursos transversais
- [x] T-050-05 Paleta de comandos global e ajuda de atalhos (RF-050-04, D4, CA-050-02)
- [x] T-050-06 Desfazer padronizado e confirmação com consequência (RF-050-05, D5, CA-050-03)
- [x] T-050-07 Valores padrão por contexto e último uso (`default_from`) (RF-050-06, D6)
- [x] T-050-08 Código de barras e QR pela câmera (RF-050-08)

Fase 3 — auditoria de todas as áreas (D8, RF-050-09, CA-050-05)
- [ ] T-050-09 Vendas, atendimento do pedido, crédito e documentos
- [ ] T-050-10 Compras, estoque, logística e campo
- [ ] T-050-11 Produção, projetos e consultoria
- [ ] T-050-12 Financeiro, contabilidade, conciliações e fechamento
- [ ] T-050-13 Cadastros, arquivos, portal do cliente
- [ ] T-050-14 Processos (BPM), esteiras, agendamento
- [ ] T-050-15 Administração, observabilidade, integrações, API pública
- [ ] T-050-16 Desenvolvimento (editor, depurador, transporte)

Depois da fase 3 — o que a auditoria mediu e ficou pendente (audit.md)
- [ ] T-050-17 Próximo passo (D3) nas 108 rotinas que gravam listadas em `tests/runtime/next_step_pending.txt`, por área na ordem do processo (Logística e campo, Projetos, Processos, Financeiro…)
- [ ] T-050-18 Desfazer (D5) onde a rotina inversa já existe: cancelar fatura, bloquear/liberar crédito, ativar/desativar cadastro
- [ ] T-050-19 Valores padrão pelo contexto (D6): recebimento, OS, apontamento de horas
- [ ] T-050-20 Conferir num navegador real os formulários mais lentos para assentar no rastreador (pedido de venda, política de atendimento, requisição de compra, devolução, projeto, bloqueio de crédito: 10–13 s com 0,7 CPU) contra o orçamento de 1 s (D2); otimizar as consultas de listas se passarem
