# 074 — Tarefas

Depende da spec 072 (canal, bateria e simulador local) e da spec 073 (folha). Antes do código: plan.md com:
- o mapeamento fato → evento sobre as mudanças vigiadas da spec 068;
- o grafo de dependências entre eventos;
- o pacote do leiaute vigente;
- a decisão de conector para a DCTFWeb (serviço de integração da Receita contratado ou passo guiado).

- [ ] T-074-01 Eventos de tabela (S-1000, S-1005, S-1010, S-1020, S-1070) a partir dos cadastros (RF-074-01)
- [ ] T-074-02 Eventos não periódicos (S-2190, S-2200, S-2205, S-2206, S-2230, S-2299, S-2300, S-2306, S-2399) a partir dos fatos, pelas mudanças vigiadas (RF-074-01, CA-074-01)
- [ ] T-074-03 Ordem e dependências por trabalhador; rejeição isolada (RF-074-02, RNF-074-02, CA-074-03)
- [ ] T-074-04 Prazos calculados e vigiados; admissão exige o evento antes do início (RF-074-03, CA-074-01)
- [ ] T-074-05 Leiaute, tabelas e regras do eSocial em pacotes com vigência; validação local com a origem (RF-074-04, RF-074-05)
- [ ] T-074-06 Periódicos (S-1200, S-1210, S-1299) no fechamento da folha (RF-074-01, CA-074-02, RNF-074-01)
- [ ] T-074-07 Totalizadores (S-5001, S-5002, S-5003, S-5011, S-5013) e conciliação automática com a folha (RF-074-06, CA-074-02)
- [ ] T-074-08 DCTFWeb: conector do serviço da Receita ou passo guiado; DARF como título conferido e conciliado (RF-074-07, CA-074-04)
- [ ] T-074-09 FGTS Digital: guia conferida com os totalizadores e lançada (RF-074-08)
- [ ] T-074-10 Alterações, retificações, S-3000 e S-1298 com impacto mostrado e quatro olhos (RF-074-09, CA-074-05)
- [ ] T-074-11 Bateria de homologação na produção restrita; produção com quatro olhos (RF-074-10)
- [ ] T-074-12 Painel "eSocial", linha do tempo do trabalhador, acesso de procurador com escopo; verificador da spec 050 (RF-074-11, RNF-074-03)
- [ ] T-074-13 Fase 3 (com a T-073-18): S-2210, S-2220 e S-2240
