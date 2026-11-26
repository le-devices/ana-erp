# 075 — Tarefas

Depende das specs 049 (fases 1 e 2), 059, 072, 073 e 074. Antes do código: plan.md com:
- o catálogo inicial por regime;
- o modelo de apuração e de livros derivados;
- o formato dos pacotes de leiaute dos arquivos SPED;
- a decisão sobre o validador oficial no CI (licença);
- as medições (RNF-075-01, RNF-075-04).

Fase 1: Simples Nacional, o caso do primeiro cliente. Fase 2: Presumido (EFD-Contribuições, ECF). Fase 3: ICMS e IPI
(EFD ICMS/IPI, DeSTDA, declarações estaduais) e Lucro Real (ECD completa, LALUR). A CBS e o IBS acompanham a
transição a cada ano.

Pendência do dono: um especialista confere os casos de teste de cada obrigação antes de ela ser oferecida em
produção (RNF-075-03).

- [ ] T-075-01 Catálogo de obrigações em pacotes (prazo, aplicabilidade, leiaute, entrega) e feriados como dado (RF-075-01)
- [ ] T-075-02 Agenda da empresa e das filiais, preparação antecipada e risco como tarefa (RF-075-02, CA-075-01)
- [ ] T-075-03 Livros e apurações derivados das fontes; ajuste com motivo e quatro olhos (RF-075-03)
- [ ] T-075-04 Apuração do Simples (RBT12, anexo, fator R da folha) e PGDAS-D, DAS e DEFIS pelo serviço da Receita ou passo guiado (RF-075-04, RF-075-07, CA-075-02)
- [ ] T-075-05 EFD-Reinf (serviços tomados, retenções de IR, CSRF) com fechamento, pelo canal, e ligação com a DCTFWeb da spec 074 (RF-075-05, CA-075-05)
- [ ] T-075-06 Guias como títulos (DAS, DARF, GNRE e guia estadual), pagas e conciliadas (RF-075-04)
- [ ] T-075-07 Impacto de mudanças em períodos declarados e retificadoras com diferença de imposto (RF-075-06, CA-075-04)
- [ ] T-075-08 Entrega pelo programa oficial: arquivo validado, passo a passo e recibo conferido com o arquivo (RF-075-05, CA-075-06)
- [ ] T-075-09 Fase 2: EFD-Contribuições, apuração de PIS e COFINS com conciliação contábil, IRPJ e CSLL do Presumido, ECF (RF-075-04, RF-075-05, CA-075-03)
- [ ] T-075-10 Fase 3: EFD ICMS/IPI (com inventário e bloco K), DeSTDA, declarações estaduais e municipais por pacote, ECD (RF-075-05)
- [ ] T-075-11 CBS e IBS: apuração própria e conferência com a apuração do governo, a cada ano da transição (RF-075-04, RF-075-10)
- [ ] T-075-12 Acesso do contador com escopo e assinatura; painel de várias empresas na fase 2 (RF-075-08)
- [ ] T-075-13 Casos de teste por obrigação (arquivo esperado) e homologação onde houver (RF-075-09, RNF-075-02, RNF-075-03)
- [ ] T-075-14 Painel "Obrigações", valores explicados até o documento, transição da reforma e assistente; verificador da spec 050 (RF-075-10, RNF-075-01)
