# 076 — Tarefas

Antes do código: plan.md com:
- o catálogo inicial: o inventário das funcionalidades atuais e dos efeitos de cada uma (menus, telas, campos,
  programas, agendamentos, regras, verificações);
- a forma do estado em memória: `persistent_term` com atualização por evento;
- a função estável no banco para as validações;
- a medição do custo da consulta (RNF-076-01).

- [ ] T-076-01 Catálogo de funcionalidades como dado: dependências, módulo da licença e efeitos declarados; `# ana:feature` nas extensões (RF-076-01)
- [ ] T-076-02 Estado por empresa, filial e ambiente, em memória em cada nó e função estável no banco; atualização por evento (RF-076-07, RF-076-08, RNF-076-01, RNF-076-02)
- [ ] T-076-03 Relação com a licença: três situações e recusa de ligar o não contratado (RF-076-02, CA-076-05)
- [ ] T-076-04 Efeitos do desligado: menus, telas, campos, paleta, assistente, checklist; `FEATURE_OFF` nos programas; agendamentos e verificações pausados; passos pulados nas rotinas (RF-076-04, CA-076-01, CA-076-06)
- [ ] T-076-05 Validações do banco que dependem de funcionalidade (centro de custo obrigatório, lote, série) lendo o estado (RF-076-04, CA-076-04)
- [ ] T-076-06 Ligar guiado: o que falta, dependências, estado "ligando" (RF-076-05, CA-076-02, CA-076-05)
- [ ] T-076-07 Desligar com ensaio do impacto e recusa quando algo ficaria pela metade, também pela API (RF-076-06, RNF-076-03, CA-076-03)
- [ ] T-076-08 Perfis prontos de negócio, editáveis, com a diferença mostrada; ligação com a implantação guiada da spec 061 (RF-076-03)
- [ ] T-076-09 Transporte entre ambientes com quatro olhos; auditoria (RF-076-07, RF-076-10, RNF-076-03)
- [ ] T-076-10 Painel "Funcionalidades" com estado, explicação e uso; sugestões de ligar e desligar (spec 051); verificador da spec 050 (RF-076-10)
- [ ] T-076-11 Bateria e rastreador do Estúdio por perfil; teste que recusa funcionalidade sem efeitos declarados; uso simulado por perfil (RF-076-09, CA-076-01)
- [ ] T-076-12 Escopo por filial (NFC-e só na loja, produção só na fábrica) nas telas e nos programas (RF-076-07, CA-076-07)
