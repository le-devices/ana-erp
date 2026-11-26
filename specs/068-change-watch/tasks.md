# 068 — Tarefas

Plano com as medições feito (plan.md, 26/11/2026): verificação instalada sob demanda, por comando; fila com apagar em lote. Antes do código: plan.md com as medições que escolhem a forma da verificação nos documentos (D5) e da fila (D8): sempre instalada com teste barato × instalada sob demanda; apagar em lote × partição por dia. Cada opção é medida em WAL, tempo de lote e trava.

- [x] T-068-01 Catálogo de entidades e campos vigiáveis como dado: rótulo, tipo, classificação e classe de volume; exclusões obrigatórias verificadas por teste; extensão pelo cliente com o portão da spec 064 (RF-068-02, D2, D7, CA-068-08)
- [x] T-068-02 Orçamento de escrita e de tempo medidos antes de tudo: linha de base de WAL e de tempo de lote nas tabelas do catálogo, com as entradas novas em `priv/disk_budget.json` (RNF-068-01, RNF-068-02)
- [ ] T-068-03 Cadastros vigiados a partir de `master.change_log`, com ponto processado em memória gravado por lote e retomada no líder (RF-068-03, D4, RNF-068-04, CA-068-02, CA-068-03, CA-068-11)
- [ ] T-068-04 Documentos vigiados por campo: evento só com regra e valor mudado, um por documento e por transação, instalação segura e sem trava longa (RF-068-04, D5, RNF-068-03, CA-068-04, CA-068-09)
- [ ] T-068-05 Alterações em massa: eventos numa gravação por comando, disparo por registro ou agrupado, padrão agrupado para importação e rotina (RF-068-05, D6, CA-068-05)
- [ ] T-068-06 Gatilho "alterado" nas regras: de/para, variação mínima, esvaziado/preenchido, origem e registro específico; ciclo e limite da spec 051 (RF-068-01, D1)
- [ ] T-068-07 Segurança no disparo e na saída: dono e escopo de dados, campo sigiloso nunca sai, dado pessoal só para conector autorizado com quatro olhos, auditoria (RF-068-06, D9, D10, RNF-068-03, CA-068-01, CA-068-06, CA-068-07)
- [ ] T-068-08 Saída por conector idempotente, ordenada por registro, limitada e assinada (RF-068-07, D11, CA-068-04)
- [ ] T-068-09 Fila curta e descartável, com retenção dos disparos e ocioso sem escrita (D8, RNF-068-01)
- [ ] T-068-10 Telas: "Avisar quando mudar" no histórico, editor com classificação visível, ensaio sobre mudanças reais, central com disparos, agrupamentos e fora do alcance; verificador da spec 050 (RF-068-08, D12, CA-068-10)
- [ ] T-068-11 Sugestão de "Avisar quando mudar" a partir de consultas repetidas ao histórico (RF-068-09)
- [ ] T-068-12 Uso simulado (spec 067): personas alterando cadastros e documentos vigiados, com oráculo de disparos esperados
- [x] T-068-13 Conta bancária do fornecedor no cadastro (`base.party_bank`), com histórico e colunas sigilosas mascaradas, para o CA-068-01 (D10)
